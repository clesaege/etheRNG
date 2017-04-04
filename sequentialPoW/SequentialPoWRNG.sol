pragma solidity ^0.4.10;

contract SequentialPoWRNG {
    
    uint public seedTime=300; // Time to give a seed.
    uint public computeTargetTime=800; // Minimum time after startBlock the PoW must take.
    uint public computeMaxTime=2400; // Maximum time of computation.
    uint public challengeTime=3600; // Time after startBlock to challenge a result.
    uint public randomFee; // The fee that must be paid in order to require a random number.
    uint public depositToFee=1000; // Submitting a result or challenge costs depositToFee * randomFee.
    uint public currentDifficulty; // The amount of time the seed should be hashed for next RNG.
    uint public jackpot; // Ether which would be given to those who manage to find the result before computeBlocks.
    uint public challengeTimePerStep=100; // The time to respond a challenge per answer.
    
    struct RN {
        bytes32 seed;
        uint difficulty;  // The amount of time the seed should be hashed.
        uint startTime; // The block where the RNG was required.
        uint result; // Resulting RNG or 0 before it is available.
        uint payout; // The amount to be paid to the first party who gives the result and the other split by token.
        uint firstSubmission; // The first submission which is valid.
        Submission[] submissions; // Submitted results.
    }
    
    struct Submission {
        address submitter;
        bytes32 commitment; // Allow submitting a hashed of the result and your address to prevent transaction ordering vulnerabilities. Note that people knowing the result can know if you submitted the right result.
        bytes32 result; // The result of applying repeated hash.
        uint deposit; // Deposit to be given back if the party has given the right value.
        Challenge[] challenges; // Challenges by people indicating that the result is false.
        bool invalidated; // True if a challenger 
    }
    
    struct Challenge {
        address challenger;
        bytes32 begin; // Firt value.
        bytes32 end; // Last value according to the defender.
        bytes32 midValue; // Value in the middle according to the submitter. 0x0 before the submiter response.
        uint distance; // Distance between begin and end.
        uint timeChallenger;
        uint timeDefender;
        uint lastInteractionTime; // Time of the last interaction.
        uint deposit; // Deposit to be given back if the party has challenged a false value.
    }
    
    RN[] public RNs;
    
    // Calling this function costs c weis (You can pay more if you want).
    modifier cost(uint c) {if (msg.value<c) throw; _;}
    
    /** Constructor. Set the initial difficulty.
     *  @param _currentDifficulty The initial difficulty.
     *  @param _randomFee The fee to be paid to request a random number.
     */
    function SequentialPoWRNG(uint _currentDifficulty, uint _randomFee) {
        currentDifficulty=_currentDifficulty;
        randomFee=_randomFee;
    }
    
    /** Ask for a random number. Must pay randomFee.
     *  @return idRN ID of the random number to be returned.
     */
    function requireRN() payable cost(randomFee) returns(uint idRN) {
        RN rn=RNs[RNs.length++];
        rn.seed=block.blockhash(block.number-1);
        rn.difficulty=currentDifficulty;
        rn.startTime=now;
        
        jackpot+=randomFee/3;
        
        return RNs.length-1; 
    }
    
    /** Change the seed of a random number still in the seeding phase.
     *  Note that you can't set the seed as you want because for seed, target, finding _personalSeed such that keccack256(seed,_personalSeed)=target is computationally impossible.
     *  @param _idRN ID of the random number to change the seed.
     *  @param _personalSeed your personal seed, should be random number between 0 and 2^255-1.
     */
    function addSeed(uint _idRN, uint _personalSeed) {
        RN rn = RNs[_idRN];
        if (rn.startTime+seedTime<now) // To late to modify the seed.
            throw;
        rn.seed=keccak256(rn.seed,_personalSeed);
    }
    
    
    /** Give the result of a random number directly (without using commitment).
     *  It is better to give the result directly if the right result has already been given.
     *  @param _idRN ID of the random number.
     *  @param _result Result of sequential PoW on the seed.
     */
    function publishResult(uint _idRN, bytes32 _result) payable cost(depositToFee*randomFee) {
        RN rn = RNs[_idRN];
        
        assert(rn.startTime+computeMaxTime>now); // Verify we can still submit.
        
        Submission submission=rn.submissions[rn.submissions.length++];
        submission.submitter=msg.sender;
        submission.result=_result;
        submission.deposit=msg.value;
    }
    
    /** Give a commitment of the result. 
     *  @param _idRN ID of the random number.
     *  @param _commitment The hash of the result and the address of the sender.
     */
    function commitResult(uint _idRN, bytes32 _commitment) payable cost(depositToFee*randomFee) {
        RN rn = RNs[_idRN];
        
        assert(rn.startTime+computeMaxTime>now); // Verify submissions are still open.
        
        Submission submission=rn.submissions[rn.submissions.length++];
        submission.submitter=msg.sender;
        submission.commitment=_commitment;
        submission.deposit=msg.value;
        
    }
    
    /** Reveal your commmitment.
     *  @param _idRN ID of the random number.
     *  @param _idSubmission ID of the submission.
     *  @param _result Result of sequential PoW on the seed.
     */
    function revealResult(uint _idRN, uint _idSubmission, bytes32 _result) {
        RN rn = RNs[_idRN];
        Submission submission=rn.submissions[_idSubmission];
        
        assert(rn.startTime+computeMaxTime>now); // Verify submissions are still open.
        assert(keccak256(_result,msg.sender)==submission.commitment); // Verify the revealed result match the commitment. Note that this also prevent someone from revealing challenges of other accounts.
        
        submission.result=_result;
    }
    
    /** Challenge a wrong result.
     *  Note that we need _t to be computed offchain because the EVM does not have a logarithm opcode, but have a exponent opcode, making it easy to verify a reult is right.
     *  @param _idRN ID of the random number.
     *  @param _idSubmission ID of the submission.
     *  @param _t Time multiplier for the difficulty, use function timeMultiplier to compute it offchain.
     */
    function challenge(uint _idRN, uint _idSubmission, uint _t) payable cost(depositToFee*randomFee) {
        RN rn = RNs[_idRN];
        Submission submission=rn.submissions[_idSubmission];
        assert(rn.startTime+challengeTime>now); // Verify challenges are still open.
        assert(2**(_t-1) <= rn.difficulty && 2**_t > rn.difficulty); // Note that underflow are not an issue since 2**0=1>rn.difficulty is false, nor are oveflows since oveflowedValue=0>rn.difficulty is also false.
        
        // Create the challenge
        Challenge challenge=submission.challenges[submission.challenges.length++];
        challenge.challenger=msg.sender;
        challenge.begin=rn.seed;
        challenge.end=submission.result;
        challenge.distance=rn.difficulty;
        challenge.timeChallenger=challengeTimePerStep*_t;
        challenge.timeDefender=challenge.timeChallenger;
        challenge.lastInteractionTime=now;
        challenge.deposit=msg.value;
    }
    
    /** 
     *  @param _midValue Value of hash^(difficulty/2)(seed).
     */
    function respondChallenge(bytes32 _midValue) {
        
    }

    
    // Constant functions.
    
    /** Return your personal commitment of a result.
     *  @param _result The result to commit.
     *  @return hash The commitment (the hash of the value).
     */
    function commitment(bytes32 _result) constant returns(bytes32 hash) {return keccak256(_result,msg.sender);}

    /** Return the time multiplier for a difficulty. It returns the first integer striclty superior to log2(_difficulty).
     *  This function is made to be executed offline since it takes a non constant amount of time.
     *  @param _difficulty The difficulty you want the maximum number of rounds.
     *  @return t The time multiplier.
     */
    function timeMultiplier(uint _difficulty) constant returns(uint t) {
        t=1;
        uint remaining=_difficulty;
        while (true) {
            remaining/=2;
            if (remaining==0)
                return t;
            else
                ++t;
        }
    }
    
    
    
}



