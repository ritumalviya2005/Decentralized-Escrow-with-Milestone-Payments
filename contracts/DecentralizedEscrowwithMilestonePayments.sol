
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title MilestoneEscrow
 * @dev Decentralized escrow system with milestone-based payments
 */
contract MilestoneEscrow {
    
    enum EscrowStatus { Active, Disputed, Completed, Cancelled }
    enum MilestoneStatus { Pending, Submitted, Approved, Disputed }
    
    struct Milestone {
        string description;
        uint256 amount;
        MilestoneStatus status;
        bool clientApproved;
        bool contractorSubmitted;
    }
    
    struct Escrow {
        address client;
        address contractor;
        address arbitrator;
        uint256 totalAmount;
        uint256 releasedAmount;
        EscrowStatus status;
        Milestone[] milestones;
        uint256 createdAt;
    }
    
    mapping(uint256 => Escrow) public escrows;
    uint256 public escrowCount;
    
    event EscrowCreated(uint256 indexed escrowId, address indexed client, address indexed contractor, uint256 totalAmount);
    event MilestoneSubmitted(uint256 indexed escrowId, uint256 milestoneIndex);
    event MilestoneApproved(uint256 indexed escrowId, uint256 milestoneIndex, uint256 amount);
    event FundsReleased(uint256 indexed escrowId, address indexed contractor, uint256 amount);
    event DisputeRaised(uint256 indexed escrowId, uint256 milestoneIndex);
    event DisputeResolved(uint256 indexed escrowId, uint256 milestoneIndex, bool approved);
    
    modifier onlyClient(uint256 _escrowId) {
        require(msg.sender == escrows[_escrowId].client, "Only client can call");
        _;
    }
    
    modifier onlyContractor(uint256 _escrowId) {
        require(msg.sender == escrows[_escrowId].contractor, "Only contractor can call");
        _;
    }
    
    modifier onlyArbitrator(uint256 _escrowId) {
        require(msg.sender == escrows[_escrowId].arbitrator, "Only arbitrator can call");
        _;
    }
    
    modifier escrowActive(uint256 _escrowId) {
        require(escrows[_escrowId].status == EscrowStatus.Active, "Escrow not active");
        _;
    }
    
    /**
     * @dev Create a new escrow with milestones
     * @param _contractor Address of the contractor
     * @param _arbitrator Address of the arbitrator
     * @param _milestoneDescriptions Array of milestone descriptions
     * @param _milestoneAmounts Array of milestone payment amounts
     */
    function createEscrow(
        address _contractor,
        address _arbitrator,
        string[] memory _milestoneDescriptions,
        uint256[] memory _milestoneAmounts
    ) external payable returns (uint256) {
        require(_contractor != address(0), "Invalid contractor");
        require(_arbitrator != address(0), "Invalid arbitrator");
        require(_milestoneDescriptions.length == _milestoneAmounts.length, "Milestone data mismatch");
        require(_milestoneDescriptions.length > 0, "At least one milestone required");
        
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < _milestoneAmounts.length; i++) {
            totalAmount += _milestoneAmounts[i];
        }
        require(msg.value == totalAmount, "Incorrect payment amount");
        
        uint256 escrowId = escrowCount++;
        Escrow storage newEscrow = escrows[escrowId];
        newEscrow.client = msg.sender;
        newEscrow.contractor = _contractor;
        newEscrow.arbitrator = _arbitrator;
        newEscrow.totalAmount = totalAmount;
        newEscrow.releasedAmount = 0;
        newEscrow.status = EscrowStatus.Active;
        newEscrow.createdAt = block.timestamp;
        
        for (uint256 i = 0; i < _milestoneDescriptions.length; i++) {
            newEscrow.milestones.push(Milestone({
                description: _milestoneDescriptions[i],
                amount: _milestoneAmounts[i],
                status: MilestoneStatus.Pending,
                clientApproved: false,
                contractorSubmitted: false
            }));
        }
        
        emit EscrowCreated(escrowId, msg.sender, _contractor, totalAmount);
        return escrowId;
    }
    
    /**
     * @dev Contractor submits milestone for approval
     * @param _escrowId ID of the escrow
     * @param _milestoneIndex Index of the milestone
     */
    function submitMilestone(uint256 _escrowId, uint256 _milestoneIndex) 
        external 
        onlyContractor(_escrowId) 
        escrowActive(_escrowId) 
    {
        Escrow storage escrow = escrows[_escrowId];
        require(_milestoneIndex < escrow.milestones.length, "Invalid milestone");
        Milestone storage milestone = escrow.milestones[_milestoneIndex];
        require(milestone.status == MilestoneStatus.Pending, "Milestone not pending");
        
        milestone.contractorSubmitted = true;
        milestone.status = MilestoneStatus.Submitted;
        
        emit MilestoneSubmitted(_escrowId, _milestoneIndex);
    }
    
    /**
     * @dev Client approves milestone and releases payment
     * @param _escrowId ID of the escrow
     * @param _milestoneIndex Index of the milestone
     */
    function approveMilestone(uint256 _escrowId, uint256 _milestoneIndex) 
        external 
        onlyClient(_escrowId) 
        escrowActive(_escrowId) 
    {
        Escrow storage escrow = escrows[_escrowId];
        require(_milestoneIndex < escrow.milestones.length, "Invalid milestone");
        Milestone storage milestone = escrow.milestones[_milestoneIndex];
        require(milestone.status == MilestoneStatus.Submitted, "Milestone not submitted");
        
        milestone.clientApproved = true;
        milestone.status = MilestoneStatus.Approved;
        
        // Release payment to contractor
        uint256 amount = milestone.amount;
        escrow.releasedAmount += amount;
        
        (bool success, ) = escrow.contractor.call{value: amount}("");
        require(success, "Payment transfer failed");
        
        emit MilestoneApproved(_escrowId, _milestoneIndex, amount);
        emit FundsReleased(_escrowId, escrow.contractor, amount);
        
        // Check if all milestones completed
        if (escrow.releasedAmount == escrow.totalAmount) {
            escrow.status = EscrowStatus.Completed;
        }
    }
    
    /**
     * @dev Raise a dispute on a milestone
     * @param _escrowId ID of the escrow
     * @param _milestoneIndex Index of the milestone
     */
    function raiseDispute(uint256 _escrowId, uint256 _milestoneIndex) 
        external 
        escrowActive(_escrowId) 
    {
        require(
            msg.sender == escrows[_escrowId].client || 
            msg.sender == escrows[_escrowId].contractor, 
            "Only client or contractor"
        );
        
        Escrow storage escrow = escrows[_escrowId];
        require(_milestoneIndex < escrow.milestones.length, "Invalid milestone");
        Milestone storage milestone = escrow.milestones[_milestoneIndex];
        require(milestone.status == MilestoneStatus.Submitted, "Can only dispute submitted milestones");
        
        milestone.status = MilestoneStatus.Disputed;
        escrow.status = EscrowStatus.Disputed;
        
        emit DisputeRaised(_escrowId, _milestoneIndex);
    }
    
    /**
     * @dev Arbitrator resolves dispute
     * @param _escrowId ID of the escrow
     * @param _milestoneIndex Index of the milestone
     * @param _approvePayment Whether to approve payment to contractor
     */
    function resolveDispute(uint256 _escrowId, uint256 _milestoneIndex, bool _approvePayment) 
        external 
        onlyArbitrator(_escrowId) 
    {
        Escrow storage escrow = escrows[_escrowId];
        require(escrow.status == EscrowStatus.Disputed, "No active dispute");
        require(_milestoneIndex < escrow.milestones.length, "Invalid milestone");
        Milestone storage milestone = escrow.milestones[_milestoneIndex];
        require(milestone.status == MilestoneStatus.Disputed, "Milestone not disputed");
        
        if (_approvePayment) {
            milestone.status = MilestoneStatus.Approved;
            milestone.clientApproved = true;
            
            uint256 amount = milestone.amount;
            escrow.releasedAmount += amount;
            
            (bool success, ) = escrow.contractor.call{value: amount}("");
            require(success, "Payment transfer failed");
            
            emit FundsReleased(_escrowId, escrow.contractor, amount);
        } else {
            milestone.status = MilestoneStatus.Pending;
            milestone.contractorSubmitted = false;
        }
        
        escrow.status = EscrowStatus.Active;
        emit DisputeResolved(_escrowId, _milestoneIndex, _approvePayment);
        
        // Check if all milestones completed
        if (escrow.releasedAmount == escrow.totalAmount) {
            escrow.status = EscrowStatus.Completed;
        }
    }
    
    /**
     * @dev Get milestone details
     * @param _escrowId ID of the escrow
     * @param _milestoneIndex Index of the milestone
     */
    function getMilestone(uint256 _escrowId, uint256 _milestoneIndex) 
        external 
        view 
        returns (
            string memory description,
            uint256 amount,
            MilestoneStatus status,
            bool clientApproved,
            bool contractorSubmitted
        ) 
    {
        Milestone memory milestone = escrows[_escrowId].milestones[_milestoneIndex];
        return (
            milestone.description,
            milestone.amount,
            milestone.status,
            milestone.clientApproved,
            milestone.contractorSubmitted
        );
    }
    
    /**
     * @dev Get number of milestones in an escrow
     * @param _escrowId ID of the escrow
     */
    function getMilestoneCount(uint256 _escrowId) external view returns (uint256) {
        return escrows[_escrowId].milestones.length;
    }
}
