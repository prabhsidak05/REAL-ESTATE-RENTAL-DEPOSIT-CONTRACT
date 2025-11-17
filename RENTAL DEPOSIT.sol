// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*
  RentalDepositEscrow — Fixed Version
  All calldata → storage dynamic array copying issues resolved.
*/

contract RentalDepositEscrow {
    // --- Basic Reentrancy Guard ---
    bool private locked;
    modifier nonReentrant() {
        require(!locked, "Reentrant");
        locked = true;
        _;
        locked = false;
    }

    // --- Roles & States ---
    enum LeaseState {Created, Funded, InspectionSubmitted, ClaimRaised, Resolved, Finalized}

    struct Inspection {
        string[] photoCIDs;
        string lockAttestationCID;
        uint256 submittedAt;
        address inspector;
    }

    struct Claim {
        uint256 amountRequested;
        string evidenceCID;
        address claimant;
        uint256 claimedAt;
        bool active;
    }

    struct Lease {
        address landlord;
        address tenant;
        uint256 deposit;
        uint256 leaseEnd;
        address inspector;
        uint256 claimWindowSeconds;
        LeaseState state;
        Inspection inspection;
        Claim claim;
    }

    mapping(uint256 => Lease) public leases;
    uint256 public nextLeaseId = 1;

    // --- Events ---
    event LeaseCreated(uint256 leaseId, address landlord, address tenant, uint256 deposit, uint256 leaseEnd);
    event DepositFunded(uint256 leaseId, address tenant, uint256 amount);
    event InspectionSubmitted(uint256 leaseId, address inspector, uint256 submittedAt);
    event ClaimRaised(uint256 leaseId, address landlord, uint256 amountRequested);
    event ClaimResolved(uint256 leaseId, uint256 tenantAmount, uint256 landlordAmount);
    event DepositFinalized(uint256 leaseId, address recipient, uint256 amount);

    // --- Modifiers ---
    modifier onlyLandlord(uint256 leaseId) {
        require(msg.sender == leases[leaseId].landlord, "Only landlord");
        _;
    }
    modifier onlyTenant(uint256 leaseId) {
        require(msg.sender == leases[leaseId].tenant, "Only tenant");
        _;
    }
    modifier onlyInspector(uint256 leaseId) {
        require(msg.sender == leases[leaseId].inspector, "Only inspector");
        _;
    }

    // --- Create Lease ---
    function createLease(
        address tenant,
        uint256 depositWei,
        uint256 leaseEndUnix,
        address inspector,
        uint256 claimWindowSeconds
    ) external returns (uint256) {
        require(tenant != address(0), "tenant 0");
        require(depositWei > 0, "deposit 0");
        require(leaseEndUnix > block.timestamp, "leaseEnd in past");

        uint256 id = nextLeaseId++;
        Lease storage L = leases[id];

        L.landlord = msg.sender;
        L.tenant = tenant;
        L.deposit = depositWei;
        L.leaseEnd = leaseEndUnix;
        L.inspector = inspector;
        L.claimWindowSeconds = claimWindowSeconds;
        L.state = LeaseState.Created;

        emit LeaseCreated(id, msg.sender, tenant, depositWei, leaseEndUnix);
        return id;
    }

    // --- Tenant Funds Deposit ---
    function fundDeposit(uint256 leaseId) external payable nonReentrant {
        Lease storage L = leases[leaseId];
        require(L.state == LeaseState.Created, "not fundable");
        require(msg.sender == L.tenant, "only tenant fund");
        require(msg.value == L.deposit, "deposit mismatch");

        L.state = LeaseState.Funded;
        emit DepositFunded(leaseId, msg.sender, msg.value);
    }

    // --- Inspector Submits Inspection (FIXED: manual deep copy) ---
    function submitInspection(
        uint256 leaseId,
        string[] calldata photoCIDs,
        string calldata lockAttestationCID
    ) external {
        Lease storage L = leases[leaseId];
        require(L.state == LeaseState.Funded || L.state == LeaseState.Created, "invalid state");
        require(block.timestamp >= L.leaseEnd, "lease not ended");

        if (L.inspector != address(0)) {
            require(msg.sender == L.inspector, "only inspector");
        } else {
            require(msg.sender == L.landlord || msg.sender == L.tenant, "no inspector set");
        }

        // *** FIX: MANUAL DEEP COPY ***
        delete L.inspection.photoCIDs;
        for (uint256 i = 0; i < photoCIDs.length; i++) {
            L.inspection.photoCIDs.push(photoCIDs[i]);
        }

        L.inspection.lockAttestationCID = lockAttestationCID;
        L.inspection.submittedAt = block.timestamp;
        L.inspection.inspector = msg.sender;
        L.state = LeaseState.InspectionSubmitted;

        emit InspectionSubmitted(leaseId, msg.sender, block.timestamp);
    }

    // --- Landlord Raises Claim ---
    function raiseClaim(uint256 leaseId, uint256 amountRequestedWei, string calldata evidenceCID)
        external
        onlyLandlord(leaseId)
    {
        Lease storage L = leases[leaseId];
        require(
            L.state == LeaseState.InspectionSubmitted ||
            L.state == LeaseState.Funded ||
            L.state == LeaseState.Created,
            "invalid state"
        );

        // claim window logic
        if (L.inspection.submittedAt > 0) {
            require(block.timestamp <= L.inspection.submittedAt + L.claimWindowSeconds, "claim window closed");
        } else {
            require(block.timestamp <= L.leaseEnd + L.claimWindowSeconds, "claim window closed");
        }

        require(amountRequestedWei <= L.deposit, "claim > deposit");

        L.claim = Claim({
            amountRequested: amountRequestedWei,
            evidenceCID: evidenceCID,
            claimant: msg.sender,
            claimedAt: block.timestamp,
            active: true
        });

        L.state = LeaseState.ClaimRaised;
        emit ClaimRaised(leaseId, msg.sender, amountRequestedWei);
    }

    // --- Inspector Resolves Claim ---
    function resolveClaim(uint256 leaseId, uint256 tenantReturnWei) external nonReentrant {
        Lease storage L = leases[leaseId];
        require(L.state == LeaseState.ClaimRaised, "no claim");
        require(L.claim.active, "inactive claim");

        if (L.inspector != address(0)) {
            require(msg.sender == L.inspector, "only inspector");
        } else {
            require(msg.sender == L.landlord, "only landlord if no inspector");
        }

        uint256 depositAmount = L.deposit;
        require(tenantReturnWei <= depositAmount, "invalid amount");

        uint256 landlordShare = depositAmount - tenantReturnWei;

        L.claim.active = false;
        L.state = LeaseState.Resolved;

        if (tenantReturnWei > 0) {
            (bool s1,) = L.tenant.call{value: tenantReturnWei}("");
            require(s1, "tenant transfer fail");
            emit DepositFinalized(leaseId, L.tenant, tenantReturnWei);
        }

        if (landlordShare > 0) {
            (bool s2,) = L.landlord.call{value: landlordShare}("");
            require(s2, "landlord transfer fail");
            emit DepositFinalized(leaseId, L.landlord, landlordShare);
        }

        emit ClaimResolved(leaseId, tenantReturnWei, landlordShare);
    }

    // --- Finalize After Claim Window ---
    function finalizeAfterWindow(uint256 leaseId) external nonReentrant {
        Lease storage L = leases[leaseId];
        require(
            L.state == LeaseState.Funded ||
            L.state == LeaseState.Created ||
            L.state == LeaseState.InspectionSubmitted,
            "invalid state"
        );
        require(!L.claim.active, "active claim");

        uint256 deadline = L.inspection.submittedAt > 0
            ? L.inspection.submittedAt + L.claimWindowSeconds
            : L.leaseEnd + L.claimWindowSeconds;

        require(block.timestamp > deadline, "window open");

        L.state = LeaseState.Finalized;

        uint256 amount = L.deposit;
        (bool sent,) = L.tenant.call{value: amount}("");
        require(sent, "transfer fail");

        emit DepositFinalized(leaseId, L.tenant, amount);
    }

    // --- Tenant Voluntarily Releases Deposit ---
    function tenantReleaseToLandlord(uint256 leaseId) external nonReentrant onlyTenant(leaseId) {
        Lease storage L = leases[leaseId];
        require(
            L.state == LeaseState.Funded ||
            L.state == LeaseState.Created ||
            L.state == LeaseState.InspectionSubmitted,
            "invalid state"
        );

        L.state = LeaseState.Finalized;

        uint256 amount = L.deposit;
        (bool sent,) = L.landlord.call{value: amount}("");
        require(sent, "transfer fail");

        emit DepositFinalized(leaseId, L.landlord, amount);
    }

    // --- View ---
    function getLeaseState(uint256 id) external view returns (LeaseState) {
        return leases[id].state;
    }

    // Reject direct ETH
    receive() external payable { revert("use fundDeposit"); }
    fallback() external payable { revert("fallback"); }
}
