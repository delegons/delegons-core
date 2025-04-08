// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "./DelegonNFT.sol";

contract BattleArena {
    DelegonNFT public delegonNFT;

    // Default starting health for each fighter.
    uint256 constant INITIAL_HEALTH = 100;
    // Maximum duration (in seconds) allowed per turn.
    uint256 constant TURN_TIMEOUT = 300;
    // Healing amount when defending.
    uint256 constant HEAL_AMOUNT = 10;
    // Damage reduction percentage when defending.
    uint256 constant DEFENSE_REDUCTION_PERCENT = 50;

    // Attack options:
    // - Standard: a basic attack that can crit.
    // - Heavy: riskier attack with a chance to miss but deals double damage.
    // - Defend: heals and activates a defensive state.
    enum AttackOption { Standard, Heavy, Defend }

    struct BattleSession {
        uint256 tokenId1;             // Fighter 1 token id.
        uint256 tokenId2;             // Fighter 2 token id.
        uint256 health1;              // Health for fighter 1.
        uint256 health2;              // Health for fighter 2.
        bool isPlayer1Turn;           // True if it's fighter1's turn.
        bool active;                  // True if the battle is ongoing.
        uint256 lastActionTimestamp;  // Timestamp of last action.
        bool player1Defending;        // Whether player1 is in defend mode.
        bool player2Defending;        // Whether player2 is in defend mode.
    }

    uint256 public nextBattleId;
    mapping(uint256 => BattleSession) public battles;

    event BattleStarted(uint256 battleId, uint256 tokenId1, uint256 tokenId2);
    // TurnResult: For attacks, 'damage' is the damage dealt; for Defend, damage is 0 and resultingHealth is new health.
    event TurnResult(
        uint256 battleId,
        uint256 actorTokenId,
        uint256 damage,
        uint256 resultingHealth,
        AttackOption attackOption
    );
    event BattleEnded(
        uint256 battleId,
        address winner,
        uint256 winnerTokenId,
        uint256 loserTokenId
    );

    constructor(address _delegonNFTAddress) {
        delegonNFT = DelegonNFT(_delegonNFTAddress);
    }

    /// @dev Starts a new battle session between two Delegons.
    /// The fighter with the higher speed starts first.
    function startBattle(uint256 tokenId1, uint256 tokenId2) external returns (uint256 battleId) {
        // Determine initial turn based on speed.
        uint8 spd1 = delegonNFT.delegonStats(tokenId1).spd;
        uint8 spd2 = delegonNFT.delegonStats(tokenId2).spd;
        bool isPlayer1Starts = spd1 >= spd2;

        battleId = nextBattleId++;
        battles[battleId] = BattleSession({
            tokenId1: tokenId1,
            tokenId2: tokenId2,
            health1: INITIAL_HEALTH,
            health2: INITIAL_HEALTH,
            isPlayer1Turn: isPlayer1Starts,
            active: true,
            lastActionTimestamp: block.timestamp,
            player1Defending: false,
            player2Defending: false
        });
        emit BattleStarted(battleId, tokenId1, tokenId2);
    }

    /// @dev Executes a single turn in an active battle.
    /// Only the owner of the acting token may call this.
    /// @param _attackOption The chosen action (Standard, Heavy, or Defend).
    function performTurn(uint256 battleId, AttackOption _attackOption) external {
        BattleSession storage battle = battles[battleId];
        require(battle.active, "Battle is not active");
        require(!hasTimedOut(battle), "Turn timed out");

        // Determine acting token and opponent token.
        uint256 actorTokenId = battle.isPlayer1Turn ? battle.tokenId1 : battle.tokenId2;
        uint256 opponentTokenId = battle.isPlayer1Turn ? battle.tokenId2 : battle.tokenId1;
        require(msg.sender == delegonNFT.ownerOf(actorTokenId), "Caller is not owner of the acting token");

        // Handle Defend action.
        if (_attackOption == AttackOption.Defend) {
            uint256 newHealth = _handleDefend(battle, battle.isPlayer1Turn);
            emit TurnResult(battleId, actorTokenId, 0, newHealth, _attackOption);
            _switchTurn(battle);
            return;
        }

        // Retrieve stats for attacker and defender.
        DelegonNFT.Stats memory attackerStats = delegonNFT.delegonStats(actorTokenId);
        DelegonNFT.Stats memory defenderStats = delegonNFT.delegonStats(opponentTokenId);

        // Calculate base damage with a random factor.
        uint256 randomFactor = _getRandomFactor(battleId);
        uint256 baseDamage = _calculateBaseDamage(attackerStats, defenderStats, randomFactor);
        uint256 attackDamage = _calculateAttackDamage(_attackOption, baseDamage, battleId, msg.sender, attackerStats.crit);

        // Check for evasion: if defender evades, attackDamage becomes 0.
        if (_attemptEvade(defenderStats.evasion)) {
            attackDamage = 0;
        }

        // If the opponent is defending, reduce damage.
        if (battle.isPlayer1Turn) {
            if (battle.player2Defending) {
                attackDamage = _applyDefenseReduction(attackDamage);
                battle.player2Defending = false;
            }
        } else {
            if (battle.player1Defending) {
                attackDamage = _applyDefenseReduction(attackDamage);
                battle.player1Defending = false;
            }
        }

        // Apply damage to the opponent.
        uint256 remainingHealth = _applyDamage(battle, attackDamage);
        emit TurnResult(battleId, actorTokenId, attackDamage, remainingHealth, _attackOption);
        battle.lastActionTimestamp = block.timestamp;

        if (remainingHealth == 0) {
            _endBattle(battle, battleId);
        } else {
            _switchTurn(battle);
        }
    }

    /// @dev Allows a player to claim victory if the opponent’s turn times out.
    function claimVictoryAfterTimeout(uint256 battleId) external {
        BattleSession storage battle = battles[battleId];
        require(battle.active, "Battle is not active");
        require(hasTimedOut(battle), "Turn has not timed out");

        address winner;
        uint256 winnerTokenId;
        uint256 loserTokenId;
        if (battle.isPlayer1Turn) {
            winner = delegonNFT.ownerOf(battle.tokenId2);
            winnerTokenId = battle.tokenId2;
            loserTokenId = battle.tokenId1;
        } else {
            winner = delegonNFT.ownerOf(battle.tokenId1);
            winnerTokenId = battle.tokenId1;
            loserTokenId = battle.tokenId2;
        }
        battle.active = false;
        emit BattleEnded(battleId, winner, winnerTokenId, loserTokenId);
    }

    /// @dev Returns true if the current turn has exceeded the allowed timeout.
    function hasTimedOut(BattleSession storage battle) internal view returns (bool) {
        return block.timestamp > battle.lastActionTimestamp + TURN_TIMEOUT;
    }

    // --- Internal Helper Functions ---

    /// @dev Returns a pseudo-random factor for damage calculations.
    function _getRandomFactor(uint256 battleId) internal view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(block.timestamp, block.difficulty, battleId))) % 10;
    }

    /// @dev Calculates base damage using attacker and defender stats plus randomness.
    function _calculateBaseDamage(DelegonNFT.Stats memory attacker, DelegonNFT.Stats memory defender, uint256 randomFactor)
    internal pure returns (uint256)
    {
        if (attacker.atk + randomFactor > defender.def) {
            return attacker.atk + randomFactor - defender.def;
        } else {
            return 1;
        }
    }

    /// @dev Determines the damage based on the selected attack option.
    /// For Standard attacks, a critical hit may double the base damage.
    function _calculateAttackDamage(
        AttackOption _attackOption,
        uint256 baseDamage,
        uint256 battleId,
        address sender,
        uint8 critChance
    ) internal view returns (uint256) {
        if (_attackOption == AttackOption.Standard) {
            // Standard attack: perform a crit check.
            uint256 critRoll = uint256(keccak256(abi.encodePacked(block.timestamp, block.number, battleId, sender))) % 100;
            if (critRoll < critChance) {
                return baseDamage * 2;
            } else {
                return baseDamage;
            }
        } else if (_attackOption == AttackOption.Heavy) {
            // Heavy attack: 20% chance to miss, otherwise double damage.
            uint256 heavyChance = uint256(keccak256(abi.encodePacked(block.timestamp, block.number, battleId, sender))) % 100;
            if (heavyChance < 20) {
                return 0;
            } else {
                return baseDamage * 2;
            }
        }
        return 0;
    }

    /// @dev Attempts to have the defender evade the attack based on their evasion stat.
    function _attemptEvade(uint8 evasion) internal view returns (bool) {
        uint256 evadeRoll = uint256(keccak256(abi.encodePacked(block.timestamp, block.number, evasion))) % 100;
        return evadeRoll < evasion;
    }

    /// @dev Applies damage to the opponent and returns the remaining health.
    function _applyDamage(BattleSession storage battle, uint256 damage) internal returns (uint256 remainingHealth) {
        if (battle.isPlayer1Turn) {
            if (damage > battle.health2) {
                damage = battle.health2;
            }
            battle.health2 -= damage;
            remainingHealth = battle.health2;
        } else {
            if (damage > battle.health1) {
                damage = battle.health1;
            }
            battle.health1 -= damage;
            remainingHealth = battle.health1;
        }
    }

    /// @dev Reduces damage by the defense reduction percentage.
    function _applyDefenseReduction(uint256 damage) internal pure returns (uint256) {
        return damage * (100 - DEFENSE_REDUCTION_PERCENT) / 100;
    }

    /// @dev Handles the defend action: heals the acting player and sets the defending flag.
    /// Returns the new health value.
    function _handleDefend(BattleSession storage battle, bool isPlayer1) internal returns (uint256 newHealth) {
        if (isPlayer1) {
            battle.health1 = battle.health1 + HEAL_AMOUNT > INITIAL_HEALTH ? INITIAL_HEALTH : battle.health1 + HEAL_AMOUNT;
            newHealth = battle.health1;
            battle.player1Defending = true;
        } else {
            battle.health2 = battle.health2 + HEAL_AMOUNT > INITIAL_HEALTH ? INITIAL_HEALTH : battle.health2 + HEAL_AMOUNT;
            newHealth = battle.health2;
            battle.player2Defending = true;
        }
    }

    /// @dev Switches the turn to the other player and updates the timestamp.
    function _switchTurn(BattleSession storage battle) internal {
        battle.isPlayer1Turn = !battle.isPlayer1Turn;
        battle.lastActionTimestamp = block.timestamp;
    }

    /// @dev Ends the battle and emits the BattleEnded event.
    function _endBattle(BattleSession storage battle, uint256 battleId) internal {
        battle.active = false;
        address winner;
        uint256 winnerTokenId;
        uint256 loserTokenId;
        if (battle.isPlayer1Turn) {
            winner = delegonNFT.ownerOf(battle.tokenId1);
            winnerTokenId = battle.tokenId1;
            loserTokenId = battle.tokenId2;
        } else {
            winner = delegonNFT.ownerOf(battle.tokenId2);
            winnerTokenId = battle.tokenId2;
            loserTokenId = battle.tokenId1;
        }
        emit BattleEnded(battleId, winner, winnerTokenId, loserTokenId);
    }
}
