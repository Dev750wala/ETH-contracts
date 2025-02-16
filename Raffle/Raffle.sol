// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
import "hardhat/console.sol";

error Raffle__UpkeepNotNeeded(uint256 currentBalance, uint256 numPlayers, uint256 raffleState);
error Raffle__TransferFailed();
error Raffle__SendMoreToEnterRaffle();
error Raffle__RaffleNotOpen();
error Raffle_WinnerIsNotSelectedYet();

contract Raffle is VRFConsumerBaseV2Plus, AutomationCompatibleInterface {
    event RequestSent(uint256 requestId, uint32 numWords);
    event RequestFulfilled(uint256 requestId, uint256[] randomWords);

    struct RequestStatus {
        bool fulfilled;
        bool exists; 
        uint256[] randomWords;
    }
    mapping(uint256 => RequestStatus) public s_requests; 

    enum RaffleState {
        OPEN,
        CALCULATING
    } // uint256 -> 0-OPEN, 1-CALCULATING

    uint256 public s_subscriptionId;

    // s_entranceFee in ETH. not USD
    uint256 private immutable i_interval;
    uint256 private immutable i_entranceFee;
    uint256 private s_lastTimeStamp;
    address private s_recentWinner;
    address payable[] private s_players;
    RaffleState private s_raffleState;

    bytes32 public keyHash = 0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae;
    uint32 public callbackGasLimit = 1_00_000;
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 public numWords = 1;
    uint256[] public requestIds;
    uint256 public lastRequestId;

    event RequestedRaffleWinner(uint256 indexed requestId);
    event RaffleEnter(address indexed player);
    // event WinnerPicked();
    event WinnerPicked(address indexed player);

    constructor(
        uint256 entranceFee,
        uint256 subscriptionId,
        uint256 interval,
        address _vrfCoordinator
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        i_interval = interval;
        s_subscriptionId = subscriptionId;
        i_entranceFee = entranceFee;
        s_raffleState = RaffleState.OPEN;
        s_lastTimeStamp = block.timestamp;
    }

    function enterRaffle() public payable {
        if (msg.value < i_entranceFee) {
            revert Raffle__SendMoreToEnterRaffle();
        }
        if (s_raffleState != RaffleState.OPEN) {
            revert Raffle__RaffleNotOpen();
        }
        s_players.push(payable(msg.sender));
        emit RaffleEnter(msg.sender);
    }

    function checkUpkeep(
        bytes memory /* checkData */
    ) public view override returns (bool upkeepNeeded, bytes memory /* performData */) {
        bool isOpen = RaffleState.OPEN == s_raffleState;
        bool timePassed = ((block.timestamp - s_lastTimeStamp) > i_interval);
        bool hasPlayers = s_players.length > 0;
        bool hasBalance = address(this).balance > 0;
        upkeepNeeded = (timePassed && isOpen && hasBalance && hasPlayers);
        return (upkeepNeeded, "0x0"); 
    }

    function performUpkeep(bytes calldata performData) external override {
        (bool upkeepNeeded, ) = checkUpkeep("");
        bool enableNativePayment = abi.decode(performData, (bool));
        if (!upkeepNeeded) {
            revert Raffle__UpkeepNotNeeded(
                address(this).balance,
                s_players.length,
                uint256(s_raffleState)
            );
        }
        s_raffleState = RaffleState.CALCULATING;

        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: s_subscriptionId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: enableNativePayment})
                )
            })
        );
        lastRequestId = requestId;
        requestIds.push(requestId);
        s_requests[requestId] = RequestStatus({
            fulfilled: false,
            exists: true,
            randomWords: new uint256[](0)
        });
        emit RequestedRaffleWinner(requestId);
    }

    function fulfillRandomWords(
        uint256 _requestId,
        uint256[] calldata _randomWords
    ) internal override {
        require(s_requests[_requestId].exists, "request not found");
        s_requests[_requestId].fulfilled = true;
        s_requests[_requestId].randomWords = _randomWords;

        if (lastRequestId == 0 || !s_requests[lastRequestId].fulfilled) {
            revert Raffle_WinnerIsNotSelectedYet();
        }
        address payable winner = s_players[
            _randomWords[0] % s_players.length
        ];
        s_recentWinner = winner;
        (bool success,) = winner.call{value: address(this).balance}("");
        s_players = new address payable[](0);
        delete s_players;
        s_raffleState = RaffleState.OPEN;
        console.log("Winner Address: %s", winner);
        s_lastTimeStamp = block.timestamp;
        if(!success) {
            revert Raffle__TransferFailed();
        }
        emit WinnerPicked(winner);
    }

    function getRaffleState() public view returns (RaffleState) {
        return s_raffleState;
    }


    function getRequestConfirmations() public pure returns (uint256) {
        return REQUEST_CONFIRMATIONS;
    }

    function getRecentWinner() public view returns (address) {
        return s_recentWinner;
    }

    function getPlayer(uint256 index) public view returns (address) {
        return s_players[index];
    }

    function getLastTimeStamp() public view returns (uint256) {
        return s_lastTimeStamp;
    }

    function getInterval() public view returns (uint256) {
        return i_interval;
    }

    function getEntranceFee() public view returns (uint256) {
        return i_entranceFee;
    }

    function getNumberOfPlayers() public view returns (uint256) {
        return s_players.length;
    }
}
