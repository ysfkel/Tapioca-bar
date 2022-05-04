// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.9;

import '@boringcrypto/boring-solidity/contracts/ERC20.sol';
import '@boringcrypto/boring-solidity/contracts/libraries/BoringERC20.sol';
import '../mixologist/Mixologist.sol';
import '../bar/BeachBar.sol';
import './ILiquidationQueue.sol';

/// @title LiquidationQueue
/// @author @0xRektora, TapiocaDAO
// TODO: Capital efficiency? (register assets to strategies)
// TODO: ERC20 impl?
contract LiquidationQueue {
    using BoringERC20 for ERC20;

    // ************ //
    // *** VARS *** //
    // ************ //

    /**
     * General information about the LiquidationQueue contract.
     */

    LiquidationQueueMeta liquidationQueueMeta; // Meta-data for this contract.
    Mixologist mixologist; // The target market.
    BeachBar beachBar; // The asset registry.

    uint256 public lqAssetId; // The liquidation queue BeachBar asset id.
    uint256 public marketAssetId; // The mixologist asset id.
    bool onlyOnce; // Contract init variable.

    /**
     * Pools & order books information.
     */

    // Bid pools, x% premium => bid pool
    // 0 ... 30 range
    // poolId => userAddress => userBidInfo.
    mapping(uint256 => mapping(address => Bidder)) public bidPools;

    // The actual order book. Entries are stored only once a bid has been activated
    // poolId => bidIndex => bidEntry).
    mapping(uint256 => mapping(uint256 => OrderBookPoolEntry)) orderBookEntries;
    // Meta-data about the order book pool
    // poolId => poolInfo.
    mapping(uint256 => OrderBookPoolInfo) orderBookInfos;

    /**
     * Ledger.
     */

    // user => amountDue.
    mapping(address => uint256) public balancesDue; // Due balance of users.

    // ***************** //
    // *** CONSTANTS *** //
    // ***************** //

    uint256 constant MAX_BID_POOLS = 30; // Maximum amount of pools.
    // `amount` * ((`bidPool` * `PREMIUM_FACTOR`) / `PREMIUM_FACTOR_PRECISION`) = premium.
    uint256 constant PREMIUM_FACTOR = 100; // Premium factor.
    uint256 constant PREMIUM_FACTOR_PRECISION = 10000; // Precision of the premium factor.

    uint256 private constant EXCHANGE_RATE_PRECISION = 1e18;

    // ************ //
    // *** INIT *** //
    // ************ //

    /// @notice Acts as a 'constructor', should be called by a Mixologist market.
    /// @param  _liquidationQueueMeta Info about the liquidations.
    function init(LiquidationQueueMeta calldata _liquidationQueueMeta)
        external
    {
        require(!onlyOnce, 'LQ: Initialized');

        // We create the BeachBar vault to store the assets.
        liquidationQueueMeta = _liquidationQueueMeta;
        Mixologist _mixologist = Mixologist(msg.sender);

        uint256 _marketAssetId = mixologist.assetId();
        beachBar = mixologist.beachBar();
        lqAssetId = _registerAsset(_mixologist, _marketAssetId);
        marketAssetId = _marketAssetId;

        // We initialize the pools to save gas on conditionals later on.
        for (uint256 i = 0; i < MAX_BID_POOLS; ) {
            _initOrderBookPoolInfo(i);
            ++i;
        }
    }

    // ************** //
    // *** EVENTS *** //
    // ************** //

    event Bid(
        address indexed bidder,
        uint256 indexed pool,
        uint256 amount,
        uint256 timestamp
    );

    event ActivateBid(
        address indexed bidder,
        uint256 indexed pool,
        uint256 amount,
        uint256 timestamp
    );

    event ExecuteBids(
        uint256 indexed pool,
        uint256 amountExecuted,
        uint256 collateralLiquidated,
        uint256 timestamp
    );

    // ***************** //
    // *** MODIFIERS *** //
    // ***************** //

    // ************* //
    // *** VIEWS *** //
    // ************* //

    function market() public view returns (string memory) {
        return mixologist.name();
    }

    function getOrderBookSize(uint256 pool) public view returns (uint256) {
        OrderBookPoolInfo memory poolInfo = orderBookInfos[pool];
        return poolInfo.nextBidPush - 1 - poolInfo.nextBidPull;
    }

    // /!\ GAS COST /!\
    function getOrderBookPoolEntries(uint256 pool)
        external
        view
        returns (OrderBookPoolEntry[] memory x)
    {
        OrderBookPoolInfo memory poolInfo = orderBookInfos[pool];
        uint256 orderBookSize = poolInfo.nextBidPush - 1 - poolInfo.nextBidPull;

        x = new OrderBookPoolEntry[](orderBookSize); // Initialize the return array.

        mapping(uint256 => OrderBookPoolEntry)
            storage entries = orderBookEntries[pool];
        for (
            (uint256 i, uint256 j) = (poolInfo.nextBidPull, 0);
            i < poolInfo.nextBidPush;

        ) {
            x[j] = entries[i]; // Copy the entry to the return array.

            ++i;
            ++j;
        }
    }

    // *********** //
    // *** TXS *** //
    // *********** //

    /// @notice Add a bid to a bid pool.
    /// @dev Create an entry in `bidPools`.
    /// @param user Who will be able to execute the bid.
    /// @param pool To which pool the bid should go.
    /// @param amount The amount in asset to bid.
    function bid(
        address user,
        uint256 pool,
        uint256 amount
    ) external {
        require(pool <= MAX_BID_POOLS, 'LQ: premium too high');

        _handleBid(amount);

        Bidder memory bidder;
        bidder.amount = amount;
        bidder.timestamp = block.timestamp;

        bidPools[pool][user] = bidder;
        emit Bid(user, pool, amount, block.timestamp);
    }

    /// @notice Activate a bid by putting it in the order book.
    /// @dev Create an entry in `orderBook` and remove it from `bidPools`.
    /// @dev Spam vector attack is mitigated the min amount req., 10min CD + activation fees.
    /// @param user The bidder.
    /// @param pool The target pool.
    function activateBid(address user, uint256 pool) external {
        Bidder memory bidder = bidPools[pool][user];
        require(
            block.timestamp + liquidationQueueMeta.activationTime >
                bidder.timestamp,
            'LQ: too soon'
        );

        OrderBookPoolInfo memory poolInfo = orderBookInfos[pool]; // Info about the pool array indexes.

        // Create a new order book entry.
        OrderBookPoolEntry memory orderBookEntry;
        orderBookEntry.bidder = user;
        orderBookEntry.bidInfo = bidder;

        // Insert the order book entry and delete the bid entry from the given pool.
        orderBookEntries[pool][poolInfo.nextBidPush] = orderBookEntry;
        delete bidPools[pool][user];

        // Update the `orderBookInfos`.
        ++poolInfo.nextBidPush;
        orderBookInfos[pool] = poolInfo;

        emit Bid(
            msg.sender,
            pool,
            orderBookEntry.bidInfo.amount,
            block.timestamp
        );
    }

    /// @notice Explain to an end user what this does
    /// @dev Should only be called from Mixologist.
    ///      Mixologist should send the `collateralAmountToLiquidate` to this contract before calling this function.
    /// Tx will fail if it can't transfer allowed BeachBar asset from Mixologist.
    /// @param collateralAmountToLiquidate The amount of collateral to liquidate.
    /// @return totalAmountExecuted The amount of asset that was executed.
    /// @return totalCollateralLiquidated The amount of collateral that was liquidated.
    function executeBids(uint256 collateralAmountToLiquidate)
        external
        returns (uint256 totalAmountExecuted, uint256 totalCollateralLiquidated)
    {
        require(msg.sender == address(mixologist), 'LQ: Only Mixologist');

        // Loop vars.
        uint256 curPoolId;
        bool isBidAvail;
        OrderBookPoolInfo memory poolInfo;
        OrderBookPoolEntry storage orderBookEntry;
        OrderBookPoolEntry memory orderBookEntryCopy;

        uint256 totalPoolAmountExecuted;
        uint256 totalPoolCollateralLiquidated;
        uint256 exchangeRate = mixologist.exchangeRate();
        uint256 discountedBidderAssetAmount;
        uint256 discountedBidderCollateralAmount;

        // We loop through all the bids for each pools until all the collateral is liquidated.
        while (totalCollateralLiquidated != collateralAmountToLiquidate) {
            // Look up for the next available bid pool.
            (curPoolId, isBidAvail) = getNextAvailBidPool();
            require(isBidAvail, 'LQ: No available bid to fill');

            poolInfo = orderBookInfos[curPoolId];

            // Reset pool vars.
            totalPoolAmountExecuted = 0;
            totalPoolCollateralLiquidated = 0;

            // While bid pool is not empty and we haven't liquidated enough collateral.
            while (
                totalCollateralLiquidated != collateralAmountToLiquidate &&
                poolInfo.nextBidPull != poolInfo.nextBidPush - 1
            ) {
                // Get the next bid.
                orderBookEntry = orderBookEntries[curPoolId][
                    poolInfo.nextBidPull
                ];
                orderBookEntryCopy = orderBookEntry;

                // Get the total amount of asset with the pool discount applied of the bidder.
                discountedBidderCollateralAmount = _getDiscountAmount(
                    _bidToCollateral(
                        orderBookEntryCopy.bidInfo.amount,
                        exchangeRate
                    ),
                    curPoolId
                );
                // Check if the bidder can pay the remaining collateral to liquidate `collateralAmountToLiquidate`.
                if (
                    discountedBidderCollateralAmount >
                    collateralAmountToLiquidate
                ) {
                    // Execute the bid.
                    balancesDue[
                        orderBookEntryCopy.bidder
                    ] += collateralAmountToLiquidate; // Write balance.
                    discountedBidderAssetAmount = _collateralToBid(
                        collateralAmountToLiquidate,
                        exchangeRate
                    );
                    orderBookEntry
                        .bidInfo
                        .amount -= discountedBidderAssetAmount; // Update bid entry amount.

                    // Update the total amount executed, the total collateral liquidated and collateral to liquidate.
                    totalPoolAmountExecuted += discountedBidderAssetAmount;
                    totalPoolCollateralLiquidated += collateralAmountToLiquidate;
                    collateralAmountToLiquidate = 0; // Since we have liquidated all the collateral.

                    break; // Break the loop to avoid unnecessary conditional check.
                } else {
                    // Execute the bid.
                    balancesDue[
                        orderBookEntryCopy.bidder
                    ] += discountedBidderCollateralAmount; // Write balance.
                    orderBookEntry.bidInfo.amount = 0; // Update bid entry amount.

                    // Update the total amount executed, the total collateral liquidated and collateral to liquidate.
                    totalPoolAmountExecuted += orderBookEntryCopy
                        .bidInfo
                        .amount;
                    totalPoolCollateralLiquidated += discountedBidderCollateralAmount;
                    collateralAmountToLiquidate -= discountedBidderCollateralAmount;

                    // Since the current bid was fulfilled, get the next one.
                    ++poolInfo.nextBidPull;
                }
            }

            // Update the totals.
            totalAmountExecuted += totalPoolAmountExecuted;
            totalCollateralLiquidated += totalPoolCollateralLiquidated;

            orderBookInfos[curPoolId] = poolInfo; // Update the pool info for the current pool.

            emit ExecuteBids(
                curPoolId,
                totalPoolAmountExecuted,
                totalPoolCollateralLiquidated,
                block.timestamp
            );
        }
    }

    /// @notice Get the next not empty bid pool in ASC order.
    /// @return i The bid pool id.
    /// @return available True if there is at least 1 bid available across all the order books.
    function getNextAvailBidPool()
        public
        view
        returns (uint256 i, bool available)
    {
        for (; i <= MAX_BID_POOLS + 1; ) {
            if (getOrderBookSize(i) != 0) {
                available = true;
                break;
            }
            ++i;
        }
    }

    // **************** //
    // *** INTERNAL *** //
    // **************** //

    /// @notice Create an asset inside of BeachBar that will hold the funds.
    /// @param _mixologist The address of Mixologist.
    function _registerAsset(Mixologist _mixologist, uint256 _marketAssetId)
        internal
        returns (uint256)
    {
        BeachBar bar = _mixologist.beachBar();

        (, address contractAddress, , ) = bar.assets(_marketAssetId);
        return
            bar.registerAsset(
                TokenType.ERC20,
                contractAddress,
                IStrategy(address(0)),
                1
            );
    }

    /// @notice Called with `init`, setup the initial pool info values.
    /// @param pool The targeted pool.
    function _initOrderBookPoolInfo(uint256 pool) internal {
        OrderBookPoolInfo memory poolInfo;
        poolInfo.poolId = uint32(pool);
        orderBookInfos[pool] = poolInfo;
    }

    /// @dev This function is called by `bid`. It transfer the BeachBar asset from the msg.sender to the LQ contract.
    /// @param amount The amount in asset to bid.
    function _handleBid(uint256 amount) internal {
        require(amount >= liquidationQueueMeta.minBidAmount, 'LQ: bid too low');

        uint256 assetId = lqAssetId;
        beachBar.transfer(
            msg.sender,
            address(this),
            assetId,
            beachBar.toShare(assetId, amount, false)
        );
    }

    /// @notice Get the discount gained from a bid in a `poolId` given an `collateralAmount`.
    /// @param collateralAmount The amount of collateral to get the discount from.
    /// @param poolId The targeted pool.
    function _getDiscountAmount(uint256 collateralAmount, uint256 poolId)
        internal
        pure
        returns (uint256)
    {
        return
            collateralAmount *
            ((poolId * PREMIUM_FACTOR) / PREMIUM_FACTOR_PRECISION);
    }

    /// @notice Convert a bid amount to a collateral amount.
    /// @param amount The amount of bid to convert.
    /// @param exchangeRate The exchange rate to use.
    function _bidToCollateral(uint256 amount, uint256 exchangeRate)
        internal
        pure
        returns (uint256)
    {
        return (amount * exchangeRate) / EXCHANGE_RATE_PRECISION;
    }

    /// @notice Convert a collateral amount to a bid amount.
    /// @param collateralAmount The amount of collateral to convert.
    /// @param exchangeRate The exchange rate to use.
    function _collateralToBid(uint256 collateralAmount, uint256 exchangeRate)
        internal
        pure
        returns (uint256)
    {
        return (collateralAmount * EXCHANGE_RATE_PRECISION) / exchangeRate;
    }
}