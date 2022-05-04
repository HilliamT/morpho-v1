// SPDX-License-Identifier: GNU AGPLv3
pragma solidity 0.8.13;

import "./interfaces/IPositionsManager.sol";
import "./interfaces/IWETH.sol";

import "./MatchingEngine.sol";

/// @title PositionsManager.
/// @notice Main Logic of Morpho Protocol, implementation of the 5 main functionalities: supply, borrow, withdraw, repay and liquidate.
contract PositionsManager is IPositionsManager, MatchingEngine {
    using DoubleLinkedList for DoubleLinkedList.List;
    using SafeTransferLib for ERC20;
    using CompoundMath for uint256;

    /// EVENTS ///

    /// @notice Emitted when the borrow peer-to-peer delta is updated.
    /// @param _poolTokenAddress The address of the market.
    /// @param _p2pBorrowDelta The borrow peer-to-peer delta after update.
    event p2pBorrowDeltaUpdated(address indexed _poolTokenAddress, uint256 _p2pBorrowDelta);

    /// @notice Emitted when the supply peer-to-peer delta is updated.
    /// @param _poolTokenAddress The address of the market.
    /// @param _p2pSupplyDelta The supply peer-to-peer delta after update.
    event p2pSupplyDeltaUpdated(address indexed _poolTokenAddress, uint256 _p2pSupplyDelta);

    /// @notice Emitted when the supply and borrow peer-to-peer amounts are updated.
    /// @param _poolTokenAddress The address of the market.
    /// @param _p2pSupplyAmount The supply peer-to-peer amount after update.
    /// @param _p2pBorrowAmount The borrow peer-to-peer amount after update.
    event P2PAmountsUpdated(
        address indexed _poolTokenAddress,
        uint256 _p2pSupplyAmount,
        uint256 _p2pBorrowAmount
    );

    /// ERRORS ///

    /// @notice Thrown when the amount repaid during the liquidation is above what is allowed to be repaid.
    error AmountAboveWhatAllowedToRepay();

    /// @notice Thrown when the amount of collateral to seize is above the collateral amount.
    error ToSeizeAboveCollateral();

    /// @notice Thrown when the borrow on Compound failed.
    error BorrowOnCompoundFailed();

    /// @notice Thrown when the redeem on Compound failed .
    error RedeemOnCompoundFailed();

    /// @notice Thrown when the repay on Compound failed.
    error RepayOnCompoundFailed();

    /// @notice Thrown when the mint on Compound failed.
    error MintOnCompoundFailed();

    /// @notice Thrown when the debt value is not above the maximum debt value.
    error DebtValueNotAboveMax();

    /// @notice Thrown when the Compound's oracle failed.
    error CompoundOracleFailed();

    /// @notice Thrown when the amount desired for a withdrawal is too small.
    error WithdrawTooSmall();

    /// STRUCTS ///

    // Struct to avoid stack too deep.
    struct WithdrawVars {
        uint256 remainingToWithdraw;
        uint256 supplyPoolIndex;
        uint256 withdrawable;
        uint256 toWithdraw;
    }

    // Struct to avoid stack too deep.
    struct RepayVars {
        uint256 p2pSupplyIndex;
        uint256 p2pBorrowIndex;
        uint256 remainingToRepay;
        uint256 poolBorrowIndex;
        uint256 feeToRepay;
        uint256 toRepay;
    }

    /// CONSTRUCTOR ///

    /// @notice Constructs the PositionsManager contract.
    /// @dev The contract is automatically marked as initialized when deployed.
    constructor() initializer {}

    /// LOGIC ///

    /// @dev Implements supply logic.
    /// @param _poolTokenAddress The address of the pool token the user wants to interact with.
    /// @param _amount The amount of token (in underlying).
    /// @param _maxGasToConsume The maximum amount of gas to consume within a matching engine loop.
    function supply(
        address _poolTokenAddress,
        uint256 _amount,
        uint256 _maxGasToConsume
    ) external {
        _enterMarketIfNeeded(_poolTokenAddress, msg.sender);
        ERC20 underlyingToken = _getUnderlying(_poolTokenAddress);
        underlyingToken.safeTransferFrom(msg.sender, address(this), _amount);

        Types.Delta storage delta = deltas[_poolTokenAddress];
        uint256 poolBorrowIndex = ICToken(_poolTokenAddress).borrowIndex();
        uint256 remainingToSupply = _amount;
        uint256 toRepay;

        /// Supply in peer-to-peer ///

        if (!noP2P[_poolTokenAddress]) {
            // Match borrow peer-to-peer delta first if any.
            uint256 matchedDelta;
            if (delta.p2pBorrowDelta > 0) {
                matchedDelta = CompoundMath.min(
                    delta.p2pBorrowDelta.mul(poolBorrowIndex),
                    remainingToSupply
                );
                if (matchedDelta > 0) {
                    toRepay += matchedDelta;
                    remainingToSupply -= matchedDelta;
                    delta.p2pBorrowDelta -= matchedDelta.div(poolBorrowIndex);
                    emit p2pBorrowDeltaUpdated(_poolTokenAddress, delta.p2pBorrowDelta);
                }
            }

            // Match pool borrowers if any.
            if (
                remainingToSupply > 0 && borrowersOnPool[_poolTokenAddress].getHead() != address(0)
            ) {
                uint256 matched = _matchBorrowers(
                    _poolTokenAddress,
                    remainingToSupply,
                    _maxGasToConsume
                ); // In underlying.

                if (matched > 0) {
                    toRepay += matched;
                    remainingToSupply -= matched;
                    delta.p2pBorrowAmount += matched.div(p2pBorrowIndex[_poolTokenAddress]);
                }
            }
        }

        if (toRepay > 0) {
            uint256 toAddInP2P = toRepay.div(p2pSupplyIndex[_poolTokenAddress]);

            delta.p2pSupplyAmount += toAddInP2P;
            supplyBalanceInOf[_poolTokenAddress][msg.sender].inP2P += toAddInP2P;
            _updateSuppliers(_poolTokenAddress, msg.sender);

            // Repay only what is necessary. The remaining tokens stays on the contracts and are claimable by the DAO.
            toRepay = Math.min(
                toRepay,
                ICToken(_poolTokenAddress).borrowBalanceCurrent(address(this)) // The debt of the contract.
            );

            _repayToPool(_poolTokenAddress, underlyingToken, toRepay); // Reverts on error.
            emit P2PAmountsUpdated(_poolTokenAddress, delta.p2pSupplyAmount, delta.p2pBorrowAmount);
        }

        /// Supply on pool ///

        if (remainingToSupply > 0) {
            supplyBalanceInOf[_poolTokenAddress][msg.sender].onPool += remainingToSupply.div(
                ICToken(_poolTokenAddress).exchangeRateStored() // Exchange rate has already been updated.
            ); // In scaled balance.
            _updateSuppliers(_poolTokenAddress, msg.sender);
            _supplyToPool(_poolTokenAddress, underlyingToken, remainingToSupply); // Reverts on error.
        }
    }

    /// @dev Implements borrow logic.
    /// @param _poolTokenAddress The address of the market the user wants to interact with.
    /// @param _amount The amount of token (in underlying).
    /// @param _maxGasToConsume The maximum amount of gas to consume within a matching engine loop.
    function borrow(
        address _poolTokenAddress,
        uint256 _amount,
        uint256 _maxGasToConsume
    ) external {
        _enterMarketIfNeeded(_poolTokenAddress, msg.sender);
        _checkUserLiquidity(msg.sender, _poolTokenAddress, 0, _amount);
        ERC20 underlyingToken = _getUnderlying(_poolTokenAddress);
        uint256 remainingToBorrow = _amount;
        uint256 toWithdraw;
        Types.Delta storage delta = deltas[_poolTokenAddress];
        uint256 poolSupplyIndex = ICToken(_poolTokenAddress).exchangeRateStored(); // Exchange rate has already been updated.
        uint256 withdrawable = ICToken(_poolTokenAddress).balanceOfUnderlying(address(this)); // The balance on pool.

        /// Borrow in peer-to-peer ///

        if (!noP2P[_poolTokenAddress]) {
            // Match supply peer-to-peer delta first if any.
            if (delta.p2pSupplyDelta > 0) {
                uint256 matchedDelta = CompoundMath.min(
                    delta.p2pSupplyDelta.mul(poolSupplyIndex),
                    remainingToBorrow,
                    withdrawable
                );
                if (matchedDelta > 0) {
                    toWithdraw += matchedDelta;
                    remainingToBorrow -= matchedDelta;
                    delta.p2pSupplyDelta -= matchedDelta.div(poolSupplyIndex);
                    emit p2pSupplyDeltaUpdated(_poolTokenAddress, delta.p2pSupplyDelta);
                }
            }

            // Match pool suppliers if any.
            if (
                remainingToBorrow > 0 && suppliersOnPool[_poolTokenAddress].getHead() != address(0)
            ) {
                uint256 matched = _matchSuppliers(
                    _poolTokenAddress,
                    CompoundMath.min(remainingToBorrow, withdrawable - toWithdraw),
                    _maxGasToConsume
                ); // In underlying.

                if (matched > 0) {
                    toWithdraw += matched;
                    remainingToBorrow -= matched;
                    deltas[_poolTokenAddress].p2pSupplyAmount += matched.div(
                        p2pSupplyIndex[_poolTokenAddress]
                    );
                }
            }
        }

        // If this value is equal to 0 the withdraw will revert on Compound.
        if (toWithdraw.div(poolSupplyIndex) > 0) {
            uint256 toAddInP2P = toWithdraw.div(p2pBorrowIndex[_poolTokenAddress]); // In peer-to-peer unit.

            deltas[_poolTokenAddress].p2pBorrowAmount += toAddInP2P;
            borrowBalanceInOf[_poolTokenAddress][msg.sender].inP2P += toAddInP2P;
            _updateBorrowers(_poolTokenAddress, msg.sender);

            _withdrawFromPool(_poolTokenAddress, toWithdraw); // Reverts on error.
            emit P2PAmountsUpdated(_poolTokenAddress, delta.p2pSupplyAmount, delta.p2pBorrowAmount);
        }

        /// Borrow on pool ///

        if (remainingToBorrow > 0) {
            borrowBalanceInOf[_poolTokenAddress][msg.sender].onPool += remainingToBorrow.div(
                ICToken(_poolTokenAddress).borrowIndex()
            ); // In cdUnit.
            _updateBorrowers(_poolTokenAddress, msg.sender);
            _borrowFromPool(_poolTokenAddress, remainingToBorrow);
        }

        underlyingToken.safeTransfer(msg.sender, _amount);
    }

    /// @dev Implements withdraw logic.
    /// @param _poolTokenAddress The address of the market the user wants to interact with.
    /// @param _amount The amount of token (in underlying).
    /// @param _supplier The address of the supplier.
    /// @param _receiver The address of the user who will receive the tokens.
    /// @param _maxGasToConsume The maximum amount of gas to consume within a matching engine loop.
    function withdraw(
        address _poolTokenAddress,
        uint256 _amount,
        address _supplier,
        address _receiver,
        uint256 _maxGasToConsume
    ) public {
        ICToken poolToken = ICToken(_poolTokenAddress);
        ERC20 underlyingToken = _getUnderlying(_poolTokenAddress);
        WithdrawVars memory vars;
        vars.remainingToWithdraw = _amount;
        vars.withdrawable = poolToken.balanceOfUnderlying(address(this));
        vars.supplyPoolIndex = poolToken.exchangeRateStored(); // Exchange rate has already been updated.

        if (_amount.div(vars.supplyPoolIndex) == 0) revert WithdrawTooSmall();

        /// Soft withdraw ///

        uint256 onPoolSupply = supplyBalanceInOf[_poolTokenAddress][_supplier].onPool;
        if (onPoolSupply > 0) {
            vars.toWithdraw = CompoundMath.min(
                onPoolSupply.mul(vars.supplyPoolIndex),
                vars.remainingToWithdraw,
                vars.withdrawable
            );
            vars.remainingToWithdraw -= vars.toWithdraw;

            supplyBalanceInOf[_poolTokenAddress][_supplier].onPool -= CompoundMath.min(
                onPoolSupply,
                vars.toWithdraw.div(vars.supplyPoolIndex)
            );
            _updateSuppliers(_poolTokenAddress, _supplier);

            if (vars.remainingToWithdraw == 0) {
                _leaveMarketIfNeeded(_poolTokenAddress, _supplier);
                // If this value is equal to 0 the withdraw will revert on Compound.
                if (vars.toWithdraw.div(vars.supplyPoolIndex) > 0)
                    _withdrawFromPool(_poolTokenAddress, vars.toWithdraw); // Reverts on error.
                underlyingToken.safeTransfer(_receiver, _amount);
                return;
            }
        }

        Types.Delta storage delta = deltas[_poolTokenAddress];
        uint256 p2pSupplyIndex = p2pSupplyIndex[_poolTokenAddress];

        /// Transfer withdraw ///

        if (vars.remainingToWithdraw > 0 && !noP2P[_poolTokenAddress]) {
            supplyBalanceInOf[_poolTokenAddress][_supplier].inP2P -= CompoundMath.min(
                supplyBalanceInOf[_poolTokenAddress][_supplier].inP2P,
                vars.remainingToWithdraw.div(p2pSupplyIndex)
            ); // In peer-to-peer unit
            _updateSuppliers(_poolTokenAddress, _supplier);

            // Match Delta if any.
            if (delta.p2pSupplyDelta > 0) {
                uint256 matchedDelta = CompoundMath.min(
                    delta.p2pSupplyDelta.mul(vars.supplyPoolIndex),
                    vars.remainingToWithdraw,
                    vars.withdrawable - vars.toWithdraw
                );

                if (matchedDelta > 0) {
                    vars.toWithdraw += matchedDelta;
                    vars.remainingToWithdraw -= matchedDelta;
                    delta.p2pSupplyDelta -= matchedDelta.div(vars.supplyPoolIndex);
                    delta.p2pSupplyAmount -= matchedDelta.div(p2pSupplyIndex);
                    emit p2pSupplyDeltaUpdated(_poolTokenAddress, delta.p2pSupplyDelta);
                }
            }

            // Match pool suppliers if any.
            if (
                vars.remainingToWithdraw > 0 &&
                suppliersOnPool[_poolTokenAddress].getHead() != address(0)
            ) {
                // Match suppliers.
                uint256 matched = _matchSuppliers(
                    _poolTokenAddress,
                    CompoundMath.min(vars.remainingToWithdraw, vars.withdrawable - vars.toWithdraw),
                    _maxGasToConsume / 2 // Divided by 2 as both matching and unmatching processes may happen in this function.
                );

                if (matched > 0) {
                    vars.remainingToWithdraw -= matched;
                    vars.toWithdraw += matched;
                }
            }
        }

        // If this value is equal to 0 the withdraw will revert on Compound.
        if (vars.toWithdraw.div(vars.supplyPoolIndex) > 0)
            _withdrawFromPool(_poolTokenAddress, vars.toWithdraw); // Reverts on error.

        /// Hard withdraw ///

        if (vars.remainingToWithdraw > 0) {
            uint256 unmatched = _unmatchBorrowers(
                _poolTokenAddress,
                vars.remainingToWithdraw,
                _maxGasToConsume / 2 // Divided by 2 as both matching and unmatching processes may happen in this function.
            );

            // If unmatched does not cover remainingToWithdraw, the difference is added to the borrow peer-to-peer delta.
            if (unmatched < vars.remainingToWithdraw) {
                delta.p2pBorrowDelta += (vars.remainingToWithdraw - unmatched).div(
                    poolToken.borrowIndex()
                );
                emit p2pBorrowDeltaUpdated(_poolTokenAddress, delta.p2pBorrowAmount);
            }

            delta.p2pSupplyAmount -= vars.remainingToWithdraw.div(p2pSupplyIndex);
            delta.p2pBorrowAmount -= unmatched.div(p2pBorrowIndex[_poolTokenAddress]);
            emit P2PAmountsUpdated(_poolTokenAddress, delta.p2pSupplyAmount, delta.p2pBorrowAmount);

            _borrowFromPool(_poolTokenAddress, vars.remainingToWithdraw); // Reverts on error.
        }

        _leaveMarketIfNeeded(_poolTokenAddress, _supplier);
        underlyingToken.safeTransfer(_receiver, _amount);
    }

    /// @dev Implements repay logic.
    /// @param _poolTokenAddress The address of the market the user wants to interact with.
    /// @param _user The address of the user.
    /// @param _amount The amount of token (in underlying).
    /// @param _maxGasToConsume The maximum amount of gas to consume within a matching engine loop.
    function repay(
        address _poolTokenAddress,
        address _user,
        uint256 _amount,
        uint256 _maxGasToConsume
    ) public {
        ICToken poolToken = ICToken(_poolTokenAddress);
        ERC20 underlyingToken = _getUnderlying(_poolTokenAddress);
        underlyingToken.safeTransferFrom(msg.sender, address(this), _amount);
        RepayVars memory vars;
        vars.remainingToRepay = _amount;
        vars.poolBorrowIndex = poolToken.borrowIndex();

        /// Soft repay ///

        if (borrowBalanceInOf[_poolTokenAddress][_user].onPool > 0) {
            uint256 borrowedOnPool = borrowBalanceInOf[_poolTokenAddress][_user].onPool;
            vars.toRepay = CompoundMath.min(
                borrowedOnPool.mul(vars.poolBorrowIndex),
                vars.remainingToRepay
            );
            vars.remainingToRepay -= vars.toRepay;

            borrowBalanceInOf[_poolTokenAddress][_user].onPool -= CompoundMath.min(
                borrowedOnPool,
                vars.toRepay.div(vars.poolBorrowIndex)
            ); // In cdUnit.
            _updateBorrowers(_poolTokenAddress, _user);

            if (vars.remainingToRepay == 0) {
                // Repay only what is necessary. The remaining tokens stays on the contracts and are claimable by the DAO.
                vars.toRepay = Math.min(
                    vars.toRepay,
                    ICToken(_poolTokenAddress).borrowBalanceCurrent(address(this)) // The debt of the contract.
                );

                if (vars.toRepay > 0) {
                    _repayToPool(_poolTokenAddress, underlyingToken, vars.toRepay); // Reverts on error.
                    _leaveMarketIfNeeded(_poolTokenAddress, _user);
                    return;
                }
            }
        }

        Types.Delta storage delta = deltas[_poolTokenAddress];
        vars.p2pSupplyIndex = p2pSupplyIndex[_poolTokenAddress];
        vars.p2pBorrowIndex = p2pBorrowIndex[_poolTokenAddress];
        borrowBalanceInOf[_poolTokenAddress][_user].inP2P -= CompoundMath.min(
            borrowBalanceInOf[_poolTokenAddress][_user].inP2P,
            vars.remainingToRepay.div(vars.p2pBorrowIndex)
        ); // In peer-to-peer unit.
        _updateBorrowers(_poolTokenAddress, _user);

        /// Fee repay ///

        // Fee = (borrowP2P - p2pBorrowDelta) - (supplyP2P - p2pSupplyDelta)
        vars.feeToRepay = CompoundMath.safeSub(
            (delta.p2pBorrowAmount.mul(vars.p2pBorrowIndex) -
                delta.p2pBorrowDelta.mul(vars.poolBorrowIndex)),
            (delta.p2pSupplyAmount.mul(vars.p2pSupplyIndex) -
                delta.p2pSupplyDelta.mul(poolToken.exchangeRateStored()))
        );
        vars.remainingToRepay -= vars.feeToRepay;

        /// Transfer repay ///

        if (vars.remainingToRepay > 0 && !noP2P[_poolTokenAddress]) {
            // Match Delta if any.
            if (delta.p2pBorrowDelta > 0) {
                uint256 matchedDelta = CompoundMath.min(
                    delta.p2pBorrowDelta.mul(vars.poolBorrowIndex),
                    vars.remainingToRepay
                );

                if (matchedDelta > 0) {
                    vars.toRepay += matchedDelta;
                    vars.remainingToRepay -= matchedDelta;
                    delta.p2pBorrowDelta -= matchedDelta.div(vars.poolBorrowIndex);
                    delta.p2pBorrowAmount -= matchedDelta.div(vars.p2pBorrowIndex);
                    emit p2pBorrowDeltaUpdated(_poolTokenAddress, delta.p2pBorrowDelta);
                }
            }

            if (
                vars.remainingToRepay > 0 &&
                borrowersOnPool[_poolTokenAddress].getHead() != address(0)
            ) {
                // Match borrowers.
                uint256 matched = _matchBorrowers(
                    _poolTokenAddress,
                    vars.remainingToRepay,
                    _maxGasToConsume / 2 // Divided by 2 as both matching and unmatching processes may happen in this function.
                );

                if (matched > 0) {
                    vars.remainingToRepay -= matched;
                    vars.toRepay += matched;
                }
            }
        }

        // Repay only what is necessary. The remaining tokens stays on the contracts and are claimable by the DAO.
        vars.toRepay = Math.min(
            vars.toRepay,
            ICToken(_poolTokenAddress).borrowBalanceCurrent(address(this)) // The debt of the contract.
        );

        if (vars.toRepay > 0) _repayToPool(_poolTokenAddress, underlyingToken, vars.toRepay); // Reverts on error.

        /// Hard repay ///

        if (vars.remainingToRepay > 0) {
            uint256 unmatched = _unmatchSuppliers(
                _poolTokenAddress,
                vars.remainingToRepay,
                _maxGasToConsume / 2 // Divided by 2 as both matching and unmatching processes may happen in this function.
            ); // Reverts on error.

            // If unmatched does not cover remainingToRepay, the difference is added to the supply peer-to-peer delta.
            if (unmatched < vars.remainingToRepay) {
                delta.p2pSupplyDelta += (vars.remainingToRepay - unmatched).div(
                    poolToken.exchangeRateStored() // Exchange rate has already been updated.
                );
                emit p2pSupplyDeltaUpdated(_poolTokenAddress, delta.p2pBorrowDelta);
            }

            delta.p2pSupplyAmount -= unmatched.div(vars.p2pSupplyIndex);
            delta.p2pBorrowAmount -= vars.remainingToRepay.div(vars.p2pBorrowIndex);
            emit P2PAmountsUpdated(_poolTokenAddress, delta.p2pSupplyAmount, delta.p2pBorrowAmount);

            _supplyToPool(_poolTokenAddress, underlyingToken, vars.remainingToRepay); // Reverts on error.
        }

        _leaveMarketIfNeeded(_poolTokenAddress, _user);
    }

    /// @notice Liquidates a position.
    /// @param _poolTokenBorrowedAddress The address of the pool token the liquidator wants to repay.
    /// @param _poolTokenCollateralAddress The address of the collateral pool token the liquidator wants to seize.
    /// @param _borrower The address of the borrower to liquidate.
    /// @param _amount The amount of token (in underlying) to repay.
    /// @return The amount of tokens seized from collateral.
    function liquidate(
        address _poolTokenBorrowedAddress,
        address _poolTokenCollateralAddress,
        address _borrower,
        uint256 _amount
    ) external returns (uint256) {
        Types.LiquidateVars memory vars;

        (vars.debtValue, vars.maxDebtValue) = _getUserHypotheticalBalanceStates(
            _borrower,
            address(0),
            0,
            0
        );
        if (vars.debtValue <= vars.maxDebtValue) revert DebtValueNotAboveMax();

        vars.borrowBalance = _getUserBorrowBalanceInOf(_poolTokenBorrowedAddress, _borrower);

        if (_amount > (vars.borrowBalance * comptroller.closeFactorMantissa()) / MAX_BASIS_POINTS)
            revert AmountAboveWhatAllowedToRepay(); // Same mechanism as Compound. Liquidator cannot repay more than part of the debt (cf close factor on Compound).

        repay(_poolTokenBorrowedAddress, _borrower, _amount, 0);

        // Comute the amount of token to seize from collateral.
        ICompoundOracle compoundOracle = ICompoundOracle(comptroller.oracle());
        vars.collateralPrice = compoundOracle.getUnderlyingPrice(_poolTokenCollateralAddress);
        vars.borrowedPrice = compoundOracle.getUnderlyingPrice(_poolTokenBorrowedAddress);
        if (vars.collateralPrice == 0 || vars.borrowedPrice == 0) revert CompoundOracleFailed();

        // Get the index and compute the number of collateral tokens to seize:
        // seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
        // seizeTokens = seizeAmount / index
        // = actualRepayAmount * (liquidationIncentive * borrowedPrice) / (collateralPrice * index)
        vars.amountToSeize = _amount
        .mul(comptroller.liquidationIncentiveMantissa())
        .mul(vars.borrowedPrice)
        .div(vars.collateralPrice);

        vars.supplyBalance = _getUserSupplyBalanceInOf(_poolTokenCollateralAddress, _borrower);

        if (vars.amountToSeize > vars.supplyBalance) revert ToSeizeAboveCollateral();

        withdraw(_poolTokenCollateralAddress, vars.amountToSeize, _borrower, msg.sender, 0);

        return vars.amountToSeize;
    }

    /// INTERNAL ///

    /// @dev Supplies underlying tokens to Compound.
    /// @param _poolTokenAddress The address of the pool token.
    /// @param _underlyingToken The underlying token of the market to supply to.
    /// @param _amount The amount of token (in underlying).
    function _supplyToPool(
        address _poolTokenAddress,
        ERC20 _underlyingToken,
        uint256 _amount
    ) internal {
        if (_poolTokenAddress == cEth) {
            IWETH(wEth).withdraw(_amount); // Turn wETH into ETH.
            ICEther(_poolTokenAddress).mint{value: _amount}();
        } else {
            _underlyingToken.safeApprove(_poolTokenAddress, _amount);
            if (ICToken(_poolTokenAddress).mint(_amount) != 0) revert MintOnCompoundFailed();
        }
    }

    /// @dev Withdraws underlying tokens from Compound.
    /// @param _poolTokenAddress The address of the pool token.
    /// @param _amount The amount of token (in underlying).
    function _withdrawFromPool(address _poolTokenAddress, uint256 _amount) internal {
        if (ICToken(_poolTokenAddress).redeemUnderlying(_amount) != 0)
            revert RedeemOnCompoundFailed();
        if (_poolTokenAddress == cEth) IWETH(address(wEth)).deposit{value: _amount}(); // Turn the ETH received in wETH.
    }

    /// @dev Borrows underlying tokens from Compound.
    /// @param _poolTokenAddress The address of the pool token.
    /// @param _amount The amount of token (in underlying).
    function _borrowFromPool(address _poolTokenAddress, uint256 _amount) internal {
        if ((ICToken(_poolTokenAddress).borrow(_amount) != 0)) revert BorrowOnCompoundFailed();
        if (_poolTokenAddress == cEth) IWETH(address(wEth)).deposit{value: _amount}(); // Turn the ETH received in wETH.
    }

    /// @dev Repays underlying tokens to Compound.
    /// @param _poolTokenAddress The address of the pool token.
    /// @param _underlyingToken The underlying token of the market to repay to.
    /// @param _amount The amount of token (in underlying).
    function _repayToPool(
        address _poolTokenAddress,
        ERC20 _underlyingToken,
        uint256 _amount
    ) internal {
        if (_poolTokenAddress == cEth) {
            IWETH(wEth).withdraw(_amount); // Turn wETH into ETH.
            ICEther(_poolTokenAddress).repayBorrow{value: _amount}();
        } else {
            _underlyingToken.safeApprove(_poolTokenAddress, _amount);
            if (ICToken(_poolTokenAddress).repayBorrow(_amount) != 0)
                revert RepayOnCompoundFailed();
        }
    }

    /// @dev Enters the user into the market if not already there.
    /// @param _user The address of the user to update.
    /// @param _poolTokenAddress The address of the market to check.
    function _enterMarketIfNeeded(address _poolTokenAddress, address _user) internal {
        if (!userMembership[_poolTokenAddress][_user]) {
            userMembership[_poolTokenAddress][_user] = true;
            enteredMarkets[_user].push(_poolTokenAddress);
        }
    }

    /// @dev Removes the user from the market if balances are null.
    /// @param _user The address of the user to update.
    /// @param _poolTokenAddress The address of the market to check.
    function _leaveMarketIfNeeded(address _poolTokenAddress, address _user) internal {
        if (
            supplyBalanceInOf[_poolTokenAddress][_user].inP2P == 0 &&
            supplyBalanceInOf[_poolTokenAddress][_user].onPool == 0 &&
            borrowBalanceInOf[_poolTokenAddress][_user].inP2P == 0 &&
            borrowBalanceInOf[_poolTokenAddress][_user].onPool == 0
        ) {
            uint256 index;
            while (enteredMarkets[_user][index] != _poolTokenAddress) {
                unchecked {
                    ++index;
                }
            }
            userMembership[_poolTokenAddress][_user] = false;

            uint256 length = enteredMarkets[_user].length;
            if (index != length - 1)
                enteredMarkets[_user][index] = enteredMarkets[_user][length - 1];
            enteredMarkets[_user].pop();
        }
    }
}
