pragma solidity 0.6.4;

import "./SafeMath.sol";
import "vrf-solidity/contracts/VRF.sol";
import "./ActiveBridgeSetLib.sol";
import "witnet-ethereum-block-relay/contracts/BlockRelayProxy.sol";
import "./WitnetRequestsBoardInterface.sol";


/**
 * @title Witnet Requests Board
 * @notice Contract to bridge requests to Witnet.
 * @dev This contract enables posting requests that Witnet bridges will insert into the Witnet network.
 * The result of the requests will be posted back to this contract by the bridge nodes too.
 * @author Witnet Foundation
 */
contract WitnetRequestsBoard is WitnetRequestsBoardInterface {

  using ActiveBridgeSetLib for ActiveBridgeSetLib.ActiveBridgeSet;

  // Expiration period after which a Witnet Request can be claimed again
  uint256 public constant CLAIM_EXPIRATION = 13;

  struct DataRequest {
    bytes dr;
    uint256 inclusionReward;
    uint256 tallyReward;
    bytes result;
    uint256 timestamp;
    uint256 drHash;
    address payable pkhClaim;
  }

  // Owner of the Witnet Request Board
  address public witnet;

  // Block Relay proxy prividing verification functions
  BlockRelayProxy public blockRelay;

  // Witnet Requests within the board
  DataRequest[] public requests;

  // Set of recently active bridges
  ActiveBridgeSetLib.ActiveBridgeSet public abs;

  // Replication factor for Active Bridge Set identities
  uint8 public repFactor;

  // Event emitted when a new DR is posted
  event PostedRequest(address indexed _from, uint256 _id);

  // Event emitted when a DR inclusion proof is posted
  event IncludedRequest(address indexed _from, uint256 _id);

  // Event emitted when a result proof is posted
  event PostedResult(address indexed _from, uint256 _id);

  // Ensures the reward is not greater than the value
  modifier payingEnough(uint256 _value, uint256 _tally) {
    require(_value >= _tally, "Transaction value needs to be equal or greater than tally reward");
    _;
  }

  // Ensures the poe is valid
  modifier poeValid(
    uint256[4] memory _poe,
    uint256[2] memory _publicKey,
    uint256[2] memory _uPoint,
    uint256[4] memory _vPointHelpers) {
    require(
      verifyPoe(
        _poe,
        _publicKey,
        _uPoint,
        _vPointHelpers) == true,
      "Not a valid PoE");
    _;
  }

  // Ensures signature (sign(msg.sender)) is valid
  modifier validSignature(
    uint256[2] memory _publicKey,
    bytes memory addrSignature) {
    require(verifySig(abi.encodePacked(msg.sender), _publicKey, addrSignature) == true, "Not a valid signature");
    _;
  }

  // Ensures the DR inclusion proof has not been reported yet
  modifier drNotIncluded(uint256 _id) {
    require(requests[_id].drHash == 0, "DR already included");
    _;
  }

  // Ensures the DR inclusion has been already reported
  modifier drIncluded(uint256 _id) {
    require(requests[_id].drHash != 0, "DR not yet included");
    _;
  }
  // Ensures the result has not been reported yet
  modifier resultNotIncluded(uint256 _id) {
    require(requests[_id].result.length == 0, "Result already included");
    _;
  }
// Ensures the VRF is valid
  modifier vrfValid(
    uint256[4] memory _poe,
    uint256[2] memory _publicKey,
    uint256[2] memory _uPoint,
    uint256[4] memory _vPointHelpers) virtual {
    require(
      VRF.fastVerify(
        _publicKey,
        _poe,
        getLastBeacon(),
        _uPoint,
        _vPointHelpers) == true,
      "Not a valid VRF");
    _;
  }

 /**
  * @notice Include an address to specify the Witnet Block Relay and a replication factor.
  * @param _blockRelayAddress BlockRelayProxy address.
  * @param _repFactor replication factor.
  */
  constructor(address _blockRelayAddress, uint8 _repFactor) public {
    blockRelay = BlockRelayProxy(_blockRelayAddress);
    witnet = msg.sender;

    // Insert an empty request so as to initialize the requests array with length > 0
    DataRequest memory request;
    requests.push(request);
    repFactor = _repFactor;
  }

  /// @dev Posts a data request into the WRB in expectation that it will be relayed and resolved in Witnet with a total reward that equals to msg.value.
  /// @param _dr The bytes corresponding to the Protocol Buffers serialization of the data request output.
  /// @param _tallyReward The amount of value that will be detracted from the transaction value and reserved for rewarding the reporting of the final result (aka tally) of the data request.
  /// @return The unique identifier of the data request.
  function postDataRequest(bytes calldata _dr, uint256 _tallyReward)
    external
    payable
    payingEnough(msg.value, _tallyReward)
    override
  returns(uint256)
  {
    uint256 _id = requests.length;
    DataRequest memory dr;
    requests.push(dr);

    requests[_id].dr = _dr;
    requests[_id].inclusionReward = SafeMath.sub(msg.value, _tallyReward);
    requests[_id].tallyReward = _tallyReward;
    requests[_id].result = "";
    requests[_id].timestamp = 0;
    requests[_id].drHash = 0;
    requests[_id].pkhClaim = address(0);
    emit PostedRequest(msg.sender, _id);
    return _id;
  }

  /// @dev Increments the rewards of a data request by adding more value to it. The new request reward will be increased by msg.value minus the difference between the former tally reward and the new tally reward.
  /// @param _id The unique identifier of the data request.
  /// @param _tallyReward The new tally reward. Needs to be equal or greater than the former tally reward.
  function upgradeDataRequest(uint256 _id, uint256 _tallyReward) external payable payingEnough(msg.value, _tallyReward) override {
    requests[_id].inclusionReward = SafeMath.add(requests[_id].inclusionReward, SafeMath.sub(msg.value, _tallyReward));
    requests[_id].tallyReward = SafeMath.add(requests[_id].tallyReward, _tallyReward);
  }

  /// @dev Checks if the data requests from a list are claimable or not.
  /// @param _ids The list of data request identifiers to be checked.
  /// @return An array of booleans indicating if data requests are claimable or not.
  function checkDataRequestsClaimability(uint256[] calldata _ids) external view returns (bool[] memory) {
    uint256 idsLength = _ids.length;
    bool[] memory validIds = new bool[](idsLength);
    for (uint i = 0; i < idsLength; i++) {
      uint256 index = _ids[i];
      validIds[i] = (requests[index].timestamp == 0 || block.number - requests[index].timestamp > CLAIM_EXPIRATION) &&
        requests[index].drHash == 0 &&
        requests[index].result.length == 0;
    }

    return validIds;
  }

  /// @dev Presents a proof of inclusion to prove that the request was posted into Witnet so as to unlock the inclusion reward that was put aside for the claiming identity (public key hash).
  /// @param _id The unique identifier of the data request.
  /// @param _poi A proof of inclusion proving that the data request appears listed in one recent block in Witnet.
  /// @param _index The index in the merkle tree.
  /// @param _blockHash The hash of the block in which the data request was inserted.
  /// @param _epoch The epoch in which the blockHash was created.
  function reportDataRequestInclusion(
    uint256 _id,
    uint256[] calldata _poi,
    uint256 _index,
    uint256 _blockHash,
    uint256 _epoch)
    external
    drNotIncluded(_id)
 {
    uint256 drOutputHash = uint256(sha256(requests[_id].dr));
    uint256 drHash = uint256(sha256(abi.encodePacked(drOutputHash, _poi[0])));
    require(
      blockRelay.verifyDrPoi(
      _poi,
      _blockHash,
      _epoch,
      _index,
      drOutputHash), "Invalid PoI");
    requests[_id].drHash = drHash;
    requests[_id].pkhClaim.transfer(requests[_id].inclusionReward);
    // Push requests[_id].pkhClaim to abs
    abs.pushActivity(requests[_id].pkhClaim, block.number);
    emit IncludedRequest(msg.sender, _id);
  }

  /// @dev Reports the result of a data request in Witnet.
  /// @param _id The unique identifier of the data request.
  /// @param _poi A proof of inclusion proving that the data in _result has been acknowledged by the Witnet network as being the final result for the data request by putting in a tally transaction inside a Witnet block.
  /// @param _index The position of the tally transaction in the tallies-only merkle tree in the Witnet block.
  /// @param _blockHash The hash of the block in which the result (tally) was inserted.
  /// @param _epoch The epoch in which the blockHash was created.
  /// @param _result The result itself as bytes.
  function reportResult(
    uint256 _id,
    uint256[] calldata _poi,
    uint256 _index,
    uint256 _blockHash,
    uint256 _epoch,
    bytes calldata _result)
    external
    drIncluded(_id)
    resultNotIncluded(_id)
 {
    // this should leave it ready for PoI
    uint256 resHash = uint256(sha256(abi.encodePacked(requests[_id].drHash, _result)));
    require(
      blockRelay.verifyTallyPoi(
      _poi,
      _blockHash,
      _epoch,
      _index,
      resHash), "Invalid PoI");
    requests[_id].result = _result;
    msg.sender.transfer(requests[_id].tallyReward);

    // Push msg.sender to abs
    abs.pushActivity(msg.sender, block.number);
    emit PostedResult(msg.sender, _id);
  }

  /// @dev Retrieves the bytes of the serialization of one data request from the WRB.
  /// @param _id The unique identifier of the data request.
  /// @return The result of the data request as bytes.
  function readDataRequest(uint256 _id) external view returns(bytes memory) {
    return requests[_id].dr;
  }

  /// @dev Retrieves the result (if already available) of one data request from the WRB.
  /// @param _id The unique identifier of the data request.
  /// @return The result of the DR
  function readResult(uint256 _id) external view override returns(bytes memory) {
    return requests[_id].result;
  }

  /// @dev Retrieves hash of the data request transaction in Witnet.
  /// @param _id The unique identifier of the data request.
  /// @return The hash of the DataRequest transaction in Witnet.
  function readDrHash(uint256 _id) external view override returns(uint256) {
    return requests[_id].drHash;
  }

  /// @dev Returns the number of data requests in the WRB.
  /// @return the number of data requests in the WRB.
  function requestsCount() external view returns(uint256) {
    return requests.length;
  }

  /// @notice Wrapper around the decodeProof from VRF library.
  /// @dev Decode VRF proof from bytes.
  /// @param _proof The VRF proof as an array composed of `[gamma-x, gamma-y, c, s]`.
  /// @return The VRF proof as an array composed of `[gamma-x, gamma-y, c, s]`.
  function decodeProof(bytes calldata _proof) external pure returns (uint[4] memory) {
    return VRF.decodeProof(_proof);
  }

  /// @notice Wrapper around the decodePoint from VRF library.
  /// @dev Decode EC point from bytes.
  /// @param _point The EC point as bytes.
  /// @return The point as `[point-x, point-y]`.
  function decodePoint(bytes calldata _point) external pure returns (uint[2] memory) {
    return VRF.decodePoint(_point);
  }

  /// @dev Wrapper around the computeFastVerifyParams from VRF library.
  /// @dev Compute the parameters (EC points) required for the VRF fast verification function..
  /// @param _publicKey The public key as an array composed of `[pubKey-x, pubKey-y]`.
  /// @param _proof The VRF proof as an array composed of `[gamma-x, gamma-y, c, s]`.
  /// @param _message The message (in bytes) used for computing the VRF.
  /// @return The fast verify required parameters as the tuple `([uPointX, uPointY], [sHX, sHY, cGammaX, cGammaY])`.
  function computeFastVerifyParams(uint256[2] calldata _publicKey, uint256[4] calldata _proof, bytes calldata _message)
    external pure returns (uint256[2] memory, uint256[4] memory)
  {
    return VRF.computeFastVerifyParams(_publicKey, _proof, _message);
  }

  /// @dev Updates the ABS activity with the block number provided.
  /// @param _blockNumber update the ABS until this block number.
  function updateAbsActivity(uint256 _blockNumber) external {
    require (_blockNumber >= abs.lastBlockNumber, "The last block number updated was higher than the one provided");
    require (_blockNumber <= block.number, "The block number provided has not been reached");

    abs.updateActivity(_blockNumber);
  }

  /// @dev Verifies if the contract is upgradable.
  /// @return true if the contract upgradable.
  function isUpgradable(address _address) external view override returns(bool) {
    if (_address == witnet) {
      return true;
    }
    return false;
  }

  /// @dev Claim drs to be posted to Witnet by the node.
  /// @param _ids Data request ids to be claimed.
  /// @param _poe PoE claiming eligibility.
  /// @param _uPoint uPoint coordinates as [uPointX, uPointY] corresponding to U = s*B - c*Y.
  /// @param _vPointHelpers helpers for calculating the V point as [(s*H)X, (s*H)Y, cGammaX, cGammaY]. V = s*H + cGamma.
  function claimDataRequests(
    uint256[] memory _ids,
    uint256[4] memory _poe,
    uint256[2] memory _publicKey,
    uint256[2] memory _uPoint,
    uint256[4] memory _vPointHelpers,
    bytes memory addrSignature)
    public
    validSignature(_publicKey, addrSignature)
    poeValid(_poe,_publicKey, _uPoint,_vPointHelpers)
  returns(bool)
  {
    for (uint i = 0; i < _ids.length; i++) {
      require(
        dataRequestCanBeClaimed(requests[_ids[i]]),
        "One of the listed data requests was already claimed"
      );
      requests[_ids[i]].pkhClaim = msg.sender;
      requests[_ids[i]].timestamp = block.number;
    }
    return true;
  }

  /// @dev Read the beacon of the last block inserted.
  /// @return bytes to be signed by the node as PoE.
  function getLastBeacon() public view virtual returns(bytes memory) {
    return blockRelay.getLastBeacon();
  }

  /// @dev Claim drs to be posted to Witnet by the node.
  /// @param _poe PoE claiming eligibility.
  /// @param _publicKey The public key as an array composed of `[pubKey-x, pubKey-y]`.
  /// @param _uPoint uPoint coordinates as [uPointX, uPointY] corresponding to U = s*B - c*Y.
  /// @param _vPointHelpers helpers for calculating the V point as [(s*H)X, (s*H)Y, cGammaX, cGammaY]. V = s*H + cGamma.
  function verifyPoe(
    uint256[4] memory _poe,
    uint256[2] memory _publicKey,
    uint256[2] memory _uPoint,
    uint256[4] memory _vPointHelpers)
    internal
    view
    vrfValid(_poe,_publicKey, _uPoint,_vPointHelpers)
  returns(bool)
  {
    uint256 vrf = uint256(VRF.gammaToHash(_poe[0], _poe[1]));
    // True if vrf/(2^{256} -1) <= repFactor/abs.activeIdentities
    if (abs.activeIdentities < repFactor) {
      return true;
    }
    // We rewrote it as vrf <= ((2^{256} -1)/abs.activeIdentities)*repFactor to gain efficiency
    if (vrf <= ((~uint256(0)/abs.activeIdentities)*repFactor)) {
      return true;
    }

    return false;
  }

  /// @dev Verifies the validity of a signature.
  /// @param _message message to be verified.
  /// @param _publicKey public key of the signer as `[pubKey-x, pubKey-y]`.
  /// @param _addrSignature the signature to verify asas r||s||v.
  /// @return true or false depending the validity.
  function verifySig(
    bytes memory _message,
    uint256[2] memory _publicKey,
    bytes memory _addrSignature)
    internal
    pure
  returns(bool)
  {
    bytes32 r;
    bytes32 s;
    uint8 v;
    assembly {
            r := mload(add(_addrSignature, 0x20))
            s := mload(add(_addrSignature, 0x40))
            v := byte(0, mload(add(_addrSignature, 0x60)))
    }

    if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
      return false;
    }

    if (v != 0 && v != 1) {
      return false;
    }
    v = 28 - v;

    bytes32 msgHash = sha256(_message);
    address hashedKey = VRF.pointToAddress(_publicKey[0], _publicKey[1]);
    return ecrecover(
      msgHash,
      v,
      r,
      s) == hashedKey;
  }

  function dataRequestCanBeClaimed(DataRequest memory _request) private view returns (bool) {
    return
      (_request.timestamp == 0 || block.number - _request.timestamp > CLAIM_EXPIRATION) &&
      _request.drHash == 0 &&
      _request.result.length == 0;
  }

}
