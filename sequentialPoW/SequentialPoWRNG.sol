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
    
    address constant BURN=0x0; // Burned coins are sent to the address 0 to make it easy to know the amount of ETH burnt.
    
    struct RN {
        bytes32 seed;
        uint difficulty;  // The amount of time the seed should be hashed.
        uint startTime; // The block where the RNG was required.
        uint result; // Resulting RNG or 0 before it is available.
        uint payout; // The amount to be paid to the first party who gives the result and the other split by token.
        uint firstSubmission; // The first submission which is valid.
        uint atStakeSubmission; // The sum of deposits of submissions that were not invalidated.
        uint differentResults; // Number of different results.
        mapping (bytes32 => uint) resultCount; // resultCount[result] is the number of valid submission with result.
        Submission[] submissions; // Submitted results.
    }
    
    struct Submission {
        address submitter;
        bytes32 commitment; // Allow submitting a hashed of the result and your address to prevent transaction ordering vulnerabilities. Note that people knowing the result can know if you submitted the right result.
        bytes32 result; // The result of applying repeated hash. If the commitment scheme is used, it is 0 before the value is revealed.
        uint deposit; // Deposit to be given back if the party has given the right value.
        Challenge[] challenges; // Challenges by people indicating that the result is false.
        bool invalidated; // True if a challenger managed to win a challenge or the submitter has been timed out.
        uint atStakeChallenge; // The sum of deposits of challenges that were not invalidated of this submission. If this is 0, all challenges have been wiped out.
        uint challengerReward; // The total amount claimable by the challengers who were not invalidated.
    }
    
    struct Challenge {
        address challenger;
        uint begin; // Where the challenged part starts.
        uint end; // Where the challenged part ends.
        bytes32 beginValue; // Firt value.
        bytes32 endValue; // Last value according to the defender.
        bytes32 midValue; // Value in the middle according to the submitter. 0x0 before the submiter response.
        uint timeChallenger;
        uint timeSubmitter;
        uint lastInteractionTime; // Time of the last interaction.
        uint deposit; // Deposit to be given back if the party has challenged a false value.
        bool invalidated; // True if the challenger failed his challenge or has been timed out.
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
    
    /** Increase the deposit of a submission.
     *  @param _rn Random number the submission relates to.
     *  @param _submission The submission.
     *  @param _value The amount to increase.
     */
    function increaseSubmissionDeposit(RN _rn, Submission _submission, uint _value) internal {
        _rn.atStakeSubmission+=_value;
        _submission.deposit+=_value;
    }
    
    /** Decrease the deposit of a submission.
     *  @param _rn Random number the submission relates to.
     *  @param _submission The submission.
     */
    function removeSubmissionDeposit(RN storage _rn, Submission storage _submission) internal {
        _rn.atStakeSubmission-=_submission.deposit;
        _submission.deposit-=0;
    }
    
    /** Add a result, keep track of the amount of different results.
     *  @param _rn The random number the result is added.
     *  @param _result The added result.
     */
    function addResult(RN storage _rn, bytes32 _result) internal {
        if (_rn.resultCount[_result]==0) // If this is a new result, increment the count.
            _rn.differentResults+=1;
        _rn.resultCount[_result]+=1;
    }
    
    /** Remove a result, keep track of the amount of different results.
     *  @param _rn The random number the result is added.
     *  @param _result The added result.
     */
    function removeResult(RN storage _rn, bytes32 _result) internal {
        _rn.resultCount[_result]-=1;
        if (_rn.resultCount[_result]==0) // If this was the last, decrement the count.
            _rn.differentResults-=1;
    }
    
    /** Give the result of a random number directly (without using commitment).
     *  It is better to give the result directly if the right result has already been given.
     *  @param _idRN ID of the random number.
     *  @param _result Result of sequential PoW on the seed.
     *  @return idSubmission The ID of the submission created.
     */
    function publishResult(uint _idRN, bytes32 _result) payable cost(depositToFee*randomFee) returns(uint idSubmission) {
        RN rn = RNs[_idRN];
        
        require(rn.startTime+computeMaxTime>now); // Verify we can still submit.
        idSubmission=rn.submissions.length++;
        Submission submission=rn.submissions[idSubmission];
        submission.submitter=msg.sender;
        submission.result=_result;
        increaseSubmissionDeposit(rn,submission,msg.value);
        
        return idSubmission;
    }
    

    
    /** Give a commitment of the result.
     *  @param _idRN ID of the random number.
     *  @param _commitment The hash of the result and the address of the sender.
     *  @return idSubmission The ID of the submission created.
     */
    function commitResult(uint _idRN, bytes32 _commitment) payable cost(depositToFee*randomFee) returns(uint idSubmission) {
        RN rn = RNs[_idRN];
        
        require(rn.startTime+computeMaxTime>now); // Verify submissions are still open.
        idSubmission=rn.submissions.length++;
        Submission submission=rn.submissions[idSubmission];
        submission.submitter=msg.sender;
        submission.commitment=_commitment;
        increaseSubmissionDeposit(rn,submission,msg.value);
        
        return idSubmission;
    }
    
    /** Reveal your commmitment.
     *  @param _idRN ID of the random number.
     *  @param _idSubmission ID of the submission.
     *  @param _result Result of sequential PoW on the seed.
     */
    function revealResult(uint _idRN, uint _idSubmission, bytes32 _result) {
        RN rn = RNs[_idRN];
        Submission submission=rn.submissions[_idSubmission];
        
        require(rn.startTime+computeMaxTime>now); // Verify submissions are still open.
        require(keccak256(_result,msg.sender)==submission.commitment); // Verify the revealed result match the commitment. Note that this also prevent someone from revealing challenges of other accounts.
        
        submission.result=_result;
    }
    
    /** Challenge a wrong result.
     *  Note that we need _t to be computed offchain because the EVM does not have a logarithm opcode, but have a exponent opcode, making it easy to verify a reult is right.
     *  @param _idRN ID of the random number.
     *  @param _idSubmission ID of the submission.
     *  @param _t Time multiplier for the difficulty, use function timeMultiplier to compute it offchain.
     *  @return idChallenge The ID of the challenge created.
     */
    function challenge(uint _idRN, uint _idSubmission, uint _t) payable cost(depositToFee*randomFee) returns (uint idChallenge) {
        RN rn = RNs[_idRN];
        Submission submission=rn.submissions[_idSubmission];
        require(rn.startTime+challengeTime>now); // Verify challenges are still open.
        require(2**(_t-1) <= rn.difficulty && 2**_t > rn.difficulty); // Note that underflow are not an issue since 2**0=1>rn.difficulty is false, nor are oveflows since oveflowedValue=0>rn.difficulty is also false.
        require(!submission.invalidated);
        
        // Create the challenge.
        idChallenge=submission.challenges.length++;
        Challenge challenge=submission.challenges[idChallenge];
        challenge.challenger=msg.sender;
        challenge.beginValue=rn.seed;
        challenge.endValue=submission.result;
        challenge.begin=0;
        challenge.end=rn.difficulty;
        challenge.timeChallenger=challengeTimePerStep*_t;
        challenge.timeSubmitter=challengeTimePerStep*_t;
        challenge.lastInteractionTime=now;
        challenge.deposit=msg.value;
        
        submission.atStakeChallenge+=challenge.deposit;// Increment the number of active challenge for the submission.
        
        return idChallenge;
    }
    
    
    /** Respond to a challenge by giving the medium value.
     *  This function should be called by the submitter.
     *  @param _idRN ID of the random number.
     *  @param _idSubmission ID of the submission.
     *  @param _idChallenge ID of the challenge.
     *  @param _midValue Value of hash^(distance/2)(begin).
     */
    function respondChallenge(uint _idRN, uint _idSubmission, uint _idChallenge, bytes32 _midValue) {
        RN rn = RNs[_idRN];
        Submission submission=rn.submissions[_idSubmission];
        Challenge challenge=submission.challenges[_idChallenge];
        
        require(!submission.invalidated);
        require(!challenge.invalidated);
        require(submission.submitter==msg.sender); // Verify that it's called by the submitter.
        require(challenge.midValue==0x0); // Verify the value has not been given yet (to avoid transaction ordering attack).
        require(now-challenge.lastInteractionTime>=challenge.timeSubmitter); // Verify that submitter still have time.
        
        challenge.midValue=_midValue; // Set the midValue.
        challenge.timeSubmitter-=(now-challenge.lastInteractionTime); // Update the time left by for submitter. 
        challenge.lastInteractionTime=now;
    }
    
    
    /** Continue the challenge in a reduced search space according to the answer of submitter.
     *  This function should be called by the challenger.
     *  @param _idRN ID of the random number.
     *  @param _idSubmission ID of the submission.
     *  @param _idChallenge ID of the challenge.
     *  @param _midValueOK True if the submitter gave the right value of hash^(distance/2)(begin), false otherwise.
     */
    function continueChallenge(uint _idRN, uint _idSubmission, uint _idChallenge, bool _midValueOK) {
        RN rn = RNs[_idRN];
        Submission submission=rn.submissions[_idSubmission];
        Challenge challenge=submission.challenges[_idChallenge];
        
        require(!submission.invalidated);
        require(!challenge.invalidated);
        require(challenge.challenger==msg.sender); // Verify that it's called by the challenger.
        require(challenge.midValue!=0x0); // Verify that a midValue has been given by the submitter.
        require(now-challenge.lastInteractionTime>=challenge.timeChallenger); // Verify that the challenger still have time.
        
        
        if (_midValueOK) { // The submitter gave the correct midValue, his means his error is in the second half.
            challenge.beginValue=challenge.midValue; 
            challenge.begin=(challenge.end-challenge.begin)/2;
        }
        else { // The submitter gave a incorrect midValue, this means his error is in the first half.
            challenge.endValue=challenge.midValue;
            challenge.end=(challenge.end-challenge.begin)/2;
        }
        
        delete challenge.midValue; // Clean the midValue. The submitter will have to give the midValue in the reduced search space.
        challenge.timeChallenger-=(now-challenge.lastInteractionTime); // Update the time left for the challenger.
        challenge.lastInteractionTime=now;
        
        assert(challenge.begin!=challenge.end); // Make sure not to reduce the space to a single point. When the distance is only one user need to call endChallenge.
    }
    
    /** Invalidate a submission.
     *  One fourth of the deposit is transfered to the jackpot.
     *  One fourth is burned.
     *  The other half can be claimed by the challengers in proportion of their deposit.
     *  @param _rn Random number of the invalidated submission.
     *  @param _submission The submission which was invalidated.
     */
    function invalidateSubmission(RN storage _rn, Submission storage _submission) internal {
        require(!_submission.invalidated);
        
        _submission.invalidated=true;
        
        // Note that some wei might be lost due to rounding but it is not an issue.
        jackpot+=_submission.deposit/4;
        BURN.transfer(_submission.deposit/4);
        _submission.challengerReward=_submission.deposit/2;
        removeSubmissionDeposit(_rn,_submission);
    }
    
    /** Invalidate a challenge.
     *  Transfer half of the challenger deposit to the submitter deposit.
     *  Transfer one fourth to the jackpot.
     *  The remaining is burned.
     *  This ensure that even if one party is always winning the jackopt, it can't make false challenges for free.
     *  @param _rn The random number of the submission the challenge belongs to.
     *  @param _submission The submission the challenge was challenging.
     *  @param _challenge The challenge which is invalidate.
     */
    function invalidateChallenge(RN storage _rn, Submission storage _submission, Challenge storage _challenge) internal {
        require(!_challenge.invalidated);
        
        _challenge.invalidated=true;
        _submission.atStakeChallenge-=_challenge.deposit;
        
        // Transfert the deposit to the submission and the jackpot.
        // Note that some wei might be lost due to rounding but it is not an issue.
        increaseSubmissionDeposit(_rn,_submission,_challenge.deposit/2);
        jackpot+=(_challenge.deposit/4); 
        BURN.transfer(_challenge.deposit/4);
        _challenge.deposit=0;
    }
    
    /** Finish a challenge, if the challenge is successfull, invalidate the submission, else invalidate the challenge.
     *  Anyone can call this function when the search space is reduced to two values.
     *  @param _idRN ID of the random number.
     *  @param _idSubmission ID of the submission.
     *  @param _idChallenge ID of the challenge.
     */
    function endChallenge(uint _idRN, uint _idSubmission, uint _idChallenge) {
        RN rn = RNs[_idRN];
        Submission submission=rn.submissions[_idSubmission];
        Challenge challenge=submission.challenges[_idChallenge];
        
        require(!submission.invalidated);
        require(!challenge.invalidated);
        require((challenge.end-challenge.begin)==1); // We can only call this function when there is only two values remaing in the search space.
        
        if(keccak256(challenge.beginValue)==challenge.endValue)
            invalidateChallenge(rn,submission,challenge); // The submitter passed the challenge, so the challenger failed.
        else // The challenger won his challenge, so the submitter failed.
            invalidateSubmission(rn,submission);
    }
    
    
    /** Invalidate a submission due to the submitter timing out in one challenge.
     *  @param _idRN ID of the random number.
     *  @param _idSubmission ID of the submission.
     *  @param _idChallenge ID of the challenge the submitter failed to respond.
     */
    function timeOutSubmitter(uint _idRN, uint _idSubmission, uint _idChallenge) {
        RN rn = RNs[_idRN];
        Submission submission=rn.submissions[_idSubmission];
        Challenge challenge=submission.challenges[_idChallenge];
        
        require(!submission.invalidated);
        require(!challenge.invalidated);
        
        require(challenge.midValue==0); // It is the turn of the submitter to respond.
        require(now-challenge.lastInteractionTime>challenge.timeSubmitter);
        
        invalidateSubmission(rn,submission);
    }
    
    /** Invalidate a submission the user failed to reveal.
     *  @param _idRN ID of the random number.
     *  @param _idSubmission ID of the submission.
     */
    function invalidateSubmissionNotRevealed(uint _idRN, uint _idSubmission) {
        RN rn = RNs[_idRN];
        Submission submission=rn.submissions[_idSubmission];
        
        require(!submission.invalidated);
        require(submission.result==0);
        
        invalidateSubmission(rn,submission);
    }
    
    /** Time out a challenger.
     *  @param _idRN ID of the random number.
     *  @param _idSubmission ID of the submission.
     *  @param _idChallenge ID of the challenge the submitter failed to respond.
     */
    function timeOutChallenger(uint _idRN, uint _idSubmission, uint _idChallenge) {
        RN rn = RNs[_idRN];
        Submission submission=rn.submissions[_idSubmission];
        Challenge challenge=submission.challenges[_idChallenge];
        
        require(!submission.invalidated);
        require(!challenge.invalidated);
        
        require(challenge.midValue!=0); // It is the turn of the challenger to respond.
        require(now-challenge.lastInteractionTime>challenge.timeChallenger);
        
        invalidateChallenge(rn,submission,challenge);
    }
    
    /** Get the deposit of a challenge back and get a part of the submission deposit.
     *  You can only do it when the challenge is invalidated (no matter who did it).
     *  The amout given is proportional to the deposit you made. Note that splitting equally is not possible because else users would be incentivized in making multiple challenges.
     *  @param _idRN ID of the random number.
     *  @param _idSubmission ID of the submission.
     *  @param _idChallenge ID of the challenge.
     */
    function getChallengeValue(uint _idRN, uint _idSubmission, uint _idChallenge) {
        RN rn = RNs[_idRN];
        Submission submission=rn.submissions[_idSubmission];
        Challenge challenge=submission.challenges[_idChallenge];
        
        require(!challenge.invalidated);
        require(submission.invalidated);
        require(msg.sender==challenge.challenger);
        
        uint amountToSend=challenge.deposit+((challenge.deposit*submission.challengerReward)/submission.atStakeChallenge);
        challenge.deposit=0;
        challenge.challenger.transfer(amountToSend);
    }
    
    /** Get the deposit of a submission back and a part.
     *  @param _idRN ID of the random number.
     *  @param _idSubmission ID of the submission.
     */
    function getSubmissionValue(uint _idRN, uint _idSubmission) {
        // TODO
    }
    
    // Constant functions 
    
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



