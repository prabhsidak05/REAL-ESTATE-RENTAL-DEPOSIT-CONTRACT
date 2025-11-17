A fully on-chain, trust-minimized rental security-deposit escrow system that protects tenants, landlords, and inspectors from misuse and disputes.
Funds remain locked in the contract until the correct stage of the rental lifecycle.

This repository contains a fixed and optimized version of the escrow contract, including:

✔ Secure deposit funding
✔ Enforced lease timeline
✔ Final inspection uploads
✔ Claim window enforcement
✔ Arbitrated fund distribution
✔ Tenant voluntary release
✔ Reentrancy protection
✔ Manual deep-copy of dynamic calldata arrays (Solidity 0.8+)

Overview

This contract allows:

Landlords to create a lease and specify terms.

Tenants to fund the escrow deposit.

Inspectors (optional) to submit move-out inspection data.

Landlords to raise a claim for damages.

Inspectors or (optionally) landlords to resolve claims.

Automatic resolution after the claim window ends.

All funds are handled via non-reentrant, timestamp-based, role-restricted logic to prevent misuse.

Key Features
🔐 Security-Focused

Manual deep copy of dynamic arrays (fixes calldata-to-storage issues)

Custom non-reentrancy guard

Strict role validation: landlord, tenant, inspector

Rejects direct ETH (only fundDeposit allowed)

📸 On-chain Inspection Record

Uploads inspection photo CIDs (IPFS)

Includes lock-attestation CID

Records inspector + timestamps immutably

⚖️ Fair Dispute Resolution

Configurable claim window

Inspector-led resolution (or landlord if no inspector exists)

Event-logged transparent distribution of funds

🧼 Clean & Predictable State Machine

Ensures safe transitions between:

Created → Funded → InspectionSubmitted → ClaimRaised → Resolved → Finalized

Contract Architecture
Main Components
Component	Purpose
Lease	Core struct storing all lease data
Inspection	Stores inspection evidence
Claim	Stores damage claim and evidence
mapping(uint256 → Lease)	Stores leases by ID
nextLeaseId	Auto-increment lease counter
nonReentrant guard	Protects all payment functions
State Machine
Created
   │
   ▼
Funded  (Tenant pays deposit)
   │
   ▼
InspectionSubmitted (Inspector uploads evidence)
   │
   ├──► ClaimRaised ───► Resolved ───► Finalized
   │
   └──► Finalized (Auto-return after claim window)


Alternate path:
Tenant can voluntarily release funds any time before a claim → Finalized

Data Structures
Lease Struct
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

Inspection Struct
struct Inspection {
    string[] photoCIDs;
    string lockAttestationCID;
    uint256 submittedAt;
    address inspector;
}

Claim Struct
struct Claim {
    uint256 amountRequested;
    string evidenceCID;
    address claimant;
    uint256 claimedAt;
    bool active;
}

Lifecycle Flow
1. Create Lease

Landlord sets:

tenant address

deposit amount

lease end timestamp

inspector (optional)

claim window duration

➡ Emits LeaseCreated

2. Tenant Funds Deposit

Tenant pays exactly the required deposit amount.

➡ Emits DepositFunded

3. Submit Inspection (After Lease End)

Inspector (or landlord/tenant if no inspector set) uploads:

array of photo CIDs

lock attestation CID

➡ Emits InspectionSubmitted

Fixed: Manual deep-copy from calldata → storage

4. Landlord May Raise Claim

Must be within claimWindow
Claim includes:

amount requested

evidence CID

➡ Emits ClaimRaised

5. Inspector Resolves Claim

Determines:

amount returned to tenant

amount kept by landlord

➡ Emits:

DepositFinalized (for each payout)

ClaimResolved

6. Auto-Finalize After Claim Window

If no claim is raised:

Full deposit returned to tenant

➡ Emits DepositFinalized

7. Tenant Voluntary Release

Tenant can release full deposit to landlord at any time before a claim.

➡ Emits DepositFinalized

Events
LeaseCreated(uint256 leaseId, address landlord, address tenant, uint256 deposit, uint256 leaseEnd)
DepositFunded(uint256 leaseId, address tenant, uint256 amount)
InspectionSubmitted(uint256 leaseId, address inspector, uint256 submittedAt)
ClaimRaised(uint256 leaseId, address landlord, uint256 amountRequested)
ClaimResolved(uint256 leaseId, uint256 tenantAmount, uint256 landlordAmount)
DepositFinalized(uint256 leaseId, address recipient, uint256 amount)

Security
✔ Reentrancy Protection

Custom lock ensures no nested calls during fund transfers.

✔ No Direct ETH

Contract rejects:

direct receive()

fallback ETH

✔ Manual Deep Copy for Calldata → Storage Array

Prevents overwriting storage references.

✔ Strict Role Enforcement

Only landlord can raise claims

Only tenant funds deposit / voluntary release

Only inspector resolves claims (or landlord when inspector is unset)

Deployment
Hardhat
npx hardhat compile
npx hardhat run scripts/deploy.js --network <network>

Remix

Paste contract into Remix.

Compile with Solidity ^0.8.19.

Deploy with no constructor params.

Example Interactions
1. Create Lease
createLease(
    tenantAddress,
    1 ether,
    1700000000,   // lease end timestamp
    inspectorAddress,
    3 days
);

2. Tenant Funds Deposit
fundDeposit{ value: 1 ether }(leaseId);

3. Inspector Submits Inspection
submitInspection(
    leaseId,
    ["QmPhoto1", "QmPhoto2"],
    "QmLockAttestation"
);

4. Raise Claim
raiseClaim(leaseId, 0.3 ether, "QmEvidence");

5. Resolve Claim
resolveClaim(leaseId, 0.7 ether); // tenant gets 0.7 ETH
