// SPDX-License-Identifier: Unlicensed

pragma solidity 0.8.4;

import './lib/AddressSet.sol';
import './lib/Bytes32Set.sol';

/// @notice : inheritable datastore layout and CRUD operations (WIP)

contract FactiivStore {

    using AddressSet for AddressSet.Set;
    using Bytes32Set for Bytes32Set.Set;

    // bytes32 public constant ROLE_FACTIIV = keccak256(abi.encodePacked('ROLE_FACTIIV'));
    // bytes32 public constant ROLE_WITNESS = keccak256(abi.encodePacked('ROLE_WITNESS'));

    enum Lifecycle {Proposed, Accepted, Closed, toRated, fromRated}
    bytes32 constant private NULL_BYTES32 = bytes32(0x0);
    uint256 public nonce;                                   // to create unique identifiers
    uint256 public minimumAmount;                           // smallest allowable USD e18

    struct User {
        Bytes32Set.Set senderJoinSet;                       // joins created by this user
        Bytes32Set.Set receiverJoinSet;                     // invitations sent to this user
        Bytes32Set.Set attestationSet;                      // all attestations about this user
        Bytes32Set.Set verificationSet;                     // attestions that claim KYC validity
    }
    AddressSet.Set userSet;                                 // all user addresses
    mapping(address => User) user;                          // random access, user details

    struct Relationship {
        bytes32 typeId;                                     // type of relationship, e.g. lend, sell
        string description;                                 // description, e.g. terms, product
        uint256 amount;                                     // amount in USD e18 (computed by UI)
        address from;                                       // sends the invitation
        address to;                                         // accepts the invitation
        Stage[] history;                                    // progress updates
        address arbitrator;                                 // relationship can have an arbitrator who can update
    }
    Bytes32Set.Set relationshipSet;                         // all user-to-user relationship ids
    mapping(bytes32 => Relationship) public relationship;   // random access, relationship details

    struct Stage {
        Lifecycle lifecycle;                                // relationship history records have a normalized step
        string metadata;                                    // arbitrary data supports future use-cases
        bytes32 fromSig;                                    // from or to participant signs each history entry
        bytes32 toSig;                                      // from or to participant signs each history entry
    }

    struct Attestation {
        address signer;                                     // testifies about the user
        address user;                                       // subject of the attestation
        bytes32 typeId;                                     // client-side interpration method
        string payload;                                     // the content of the attestation
    }
    Bytes32Set.Set attestationSet;                          // all attestion ids
    mapping(bytes32 => Attestation) public attestation;     // random access, attestion details

    Bytes32Set.Set relationshipTypeSet;                     // defined relationship types
    mapping(bytes32 => string) public relationshipTypeDesc; // relationship type descriptions

    Bytes32Set.Set attestationTypeSet;                      // defined attestation types
    mapping(bytes32 => string) public attestationTypeDesc;  // attestation type descriptions

    event newRelationshipType(address indexed relay, address indexed sender, bytes32 id, string description);
    event newAttestationType(address indexed relay, address indexed sender, bytes32 id, string description);
    event newAttestation(address indexed relay, address indexed signer, address indexed user, bytes32 id, bytes32 typeId, string payload);
    event updateAttestation(address indexed relay, address indexed signer, address indexed user, bytes32 id, bytes32 typeId, string payload);
    event NewRelationship(
            address indexed relay, 
            address indexed signer,
            bytes32 typeId,
            string desc,
            uint256 amount,
            address to,
            bytes32 signature);
    event AcceptRelationship(
            address indexed relay, 
            address indexed signer,
            bytes32 typeId,
            string desc,
            uint256 amount,
            address from,
            bytes32 signature);     
    event UpdateRelationship(
            address indexed relay, 
            address indexed signer,
            bytes32 id,
            bytes32 fromSig,
            bytes32 toSig,
            Lifecycle lifecycle,
            string metadata
        );       

    /// @dev the following internal functions should be called by a child contract that inherits from this one    
    /// use this contract to implement basic CRUD operations with validation checks.
    /// call from contracts that inherit it and implement the user interface and business logic.

    function _createRelationshipType(address relay, address from, bytes32 id, string memory desc) internal {
        relationshipTypeSet.insert(id);
        relationshipTypeDesc[id] = desc;
        emit newRelationshipType(relay, from, id, desc); 
    }

    function _createAttestationType(address relay, address from, bytes32 id, string memory desc) internal {
        attestationTypeSet.insert(id);
        attestationTypeDesc[id] = desc;
        emit newAttestationType(relay, from, id, desc); 
    }

    function _createAttestation(address relay, address from, address subject, bytes32 typeId, string memory payload) internal returns(bytes32 id) {
        id = _keyGen();
        Attestation storage a = attestation[id];
        a.signer = from; 
        a.user = subject;
        a.typeId = typeId;
        a.payload = payload;
        emit newAttestation(relay, from, subject, id, typeId, payload);
    }

    /// @dev : attestion type is unchangeable, by design
    
    function _updateAttestion(address relay, address from, address subject, bytes32 id, string memory payload) internal {
        require(attestationSet.exists(id), 'FactiivStore.updateAttestion : unknown attestation');
        Attestation storage a = attestation[id];
        a.payload = payload;
        emit updateAttestation(relay, from, subject, id, a.typeId, payload);
    }

    /// @dev : new relationships default to Proposed with no arbitrator or special data

    function _createRelationship(
        address relay, 
        address from, 
        bytes32 typeId,
        string memory desc,
        uint256 amount,
        address to,
        bytes32 signature
    ) internal returns(bytes32 id) {
        require(relationshipTypeSet.exists(typeId), 'FactiivStore.createRelationship : unknown typeId');
        require(amount > minimumAmount, 'FactiivStore.createRelationship : amount below minimum');
        require(msg.sender != to, 'FactiivStore.createRelationship: to = sender');
        id = _keyGen();
        Stage memory s = Stage({
            lifecycle: Lifecycle.Proposed,
            metadata: '',
            fromSig: signature,
            toSig: ''
        });
        Relationship storage r = relationship[id];
        r.typeId = typeId;
        r.amount = amount;
        r.from = from; 
        r.to = to;
        r.history.push(s);
        emit NewRelationship(
            relay, 
            from,
            typeId,
            desc,
            amount,
            to,
            signature); 
    }

    function _acceptRelationship(address relay, address from, bytes32 id, bytes32 signature) internal {
        Relationship storage r = relationship[id];
        require(relationshipSet.exists(id), 'FactiivStore.acceptRelationship : unknown relationship');
        require(r.to == msg.sender, 'FactiivStore.acceptRelationship : not receiver');
        // proposed relationships always have only one history entry
        require(r.history.length == 1, 'FactiivStore.acceptRelationship : not proposed');
        Stage memory s = Stage({
            lifecycle: Lifecycle.Accepted,
            metadata: '',
            fromSig: '',
            toSig: signature
        });
        r.history.push(s);
        emit AcceptRelationship(
            relay, 
            from,
            r.typeId,
            r.description,
            r.amount,
            r.from,
            signature);       
    }

    function _updateRelationship(
        address relay, 
        address from, 
        bytes32 id, 
        bytes32 signature, 
        Lifecycle lifecycle, 
        string memory metadata
    ) internal {
        Relationship storage r = relationship[id];
        require(relationshipSet.exists(id), 'FactiivStore.acceptRelationship : unknown relationship');
        require(r.to == from || r.from == from, 'FactiivStore.acceptRelationship : not a participant');
        bytes32 fromSig = (r.from == from) ? signature : NULL_BYTES32;
        bytes32 toSig = (r.to == from) ? signature : NULL_BYTES32; 
        Stage memory s = Stage({
            lifecycle: lifecycle,
            metadata: metadata,
            fromSig: fromSig,
            toSig: toSig
        });
        r.history.push(s);
        emit UpdateRelationship(
            relay, 
            from,
            id,
            fromSig,
            toSig,
            lifecycle,
            metadata
        );
    }

    /*
     * TODO: Arbitrator can be assigned to a relationship by ROLE_FACTIIV
     * The arbitator will be allowed to append to history, or remove history
     * User requests arbitration (correction), arbitrator resolves (off-chain), arbitrator updates the state
     */

    function _keyGen() private returns(bytes32 uid) {
        nonce++;
        uid = keccak256(abi.encodePacked(address(this), nonce));
    }

}