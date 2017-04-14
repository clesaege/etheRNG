/** @title Random number generator using sequential proof of work.
 *  @author Clément Lesaege - <clement@lesaege.com>
 */

pragma solidity ^0.4.10;

contract SequentialPoWRNG {
    
    uint public seedTime=300; // Time to give a seed.
    uint public computeTargetTime=800; // Minimum time after startBlock the PoW must take. If someone manage to get lower, he receives a part of the jackpot and the difficulty is increased.
    uint public computeMaxTime=2400; // Maximum time of computation.
    uint public challengeTime=3600; // Time after startBlock to challenge a result.
    uint public randomFee; // The fee that must be paid in order to require a random number.
    uint public depositToFee=1000; // Submitting a result or challenge costs depositToFee * randomFee.
    uint public currentDifficulty; // The amount of time the seed should be hashed for next RNG.
    uint public currentTotalTimeToRespond; // Is equal to timeMultiplier(currentDifficulty)*challengeTimePerStep .
    uint public jackpot; // Ether which would be given to those who manage to find the result before computeBlocks.
    uint public challengeTimePerStep=100; // The time to respond a challenge per answer.
    
    address constant BURN=0x0; // Burned coins are sent to the address 0 to make it easy to know the amount of ETH burnt.
    uint8 constant MAX_FIRST_SUBMISSION_UPDATE=100; // The maximum amount increase of firstSubmission during a function call. This prevent looping out of gas when calling updateFirstSubmission.
    
    struct RN {
        bytes32 seed;
        uint difficulty;  // The amount of time the seed should be hashed.
        uint startTime; // The block where the RNG was required.
        uint result; // Resulting RNG or 0 before it is available.
        uint payout; // The amount to be paid to the first party who gives the result and the amount to be split between the parties who made a valid submission.
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
        uint time; // When the submission was made.
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
    modifier cost(uint c) {require(msg.value>=c); _;}
    
    /** @dev Constructor. Set the initial difficulty.
     *  @param _currentDifficulty The initial difficulty.
     *  @param _randomFee The fee to be paid to request a random number.
     */
    function SequentialPoWRNG(uint _currentDifficulty, uint _randomFee) {
        currentDifficulty=_currentDifficulty;
        currentTotalTimeToRespond=challengeTimePerStep*timeMultiplier(currentDifficulty);
        randomFee=_randomFee;
    }
    
    /** @dev Ask for a random number. Must pay randomFee.
     *  @return idRN ID of the random number to be returned.
     */
    function requireRN() payable cost(randomFee) returns(uint idRN) {
        RN rn=RNs[RNs.length++];
        rn.seed=block.blockhash(block.number-1);
        rn.difficulty=currentDifficulty;
        rn.startTime=now;
        uint payout=msg.value/3; // The amount to be put in the jackpot, given to the first submitter and split between all the submitters.
        jackpot+=payout;
        rn.payout=payout;
        
        return RNs.length-1; 
    }
    
    /** @dev Change the seed of a random number still in the seeding phase.
     *  Note that you can't set the seed as you want because for seed, target, finding _personalSeed such that keccack256(seed,_personalSeed)=target is computationally impossible.
     *  @param _idRN ID of the random number to change the seed.
     *  @param _personalSeed your personal seed, should be random number between 0 and 2^255-1.
     */
    function addSeed(uint _idRN, uint _personalSeed) {
        RN rn = RNs[_idRN];
        
        require(rn.startTime+seedTime>=now); // To late to modify the seed.
        
        rn.seed=keccak256(rn.seed,_personalSeed);
    }
    
    /** @dev Increase the deposit of a submission.
     *  @param _rn Random number the submission relates to.
     *  @param _submission The submission.
     *  @param _value The amount to increase.
     */
    function increaseSubmissionDeposit(RN _rn, Submission _submission, uint _value) internal {
        _rn.atStakeSubmission+=_value;
        _submission.deposit+=_value;
    }
    
    /** @dev Decrease the deposit of a submission.
     *  @param _rn Random number the submission relates to.
     *  @param _submission The submission.
     */
    function removeSubmissionDeposit(RN storage _rn, Submission storage _submission) internal {
        _rn.atStakeSubmission-=_submission.deposit;
        _submission.deposit-=0;
    }
    
    /** @dev Add a result, keep track of the amount of different results.
     *  @param _rn The random number the result is added.
     *  @param _result The added result.
     */
    function addResult(RN storage _rn, bytes32 _result) internal {
        if (_rn.resultCount[_result]==0) // If this is a new result, increment the count.
            _rn.differentResults+=1;
        _rn.resultCount[_result]+=1;
    }
    
    /** @dev Remove a result, keep track of the amount of different results.
     *  @param _rn The random number the result is added.
     *  @param _result The added result.
     */
    function removeResult(RN storage _rn, bytes32 _result) internal {
        _rn.resultCount[_result]-=1;
        if (_rn.resultCount[_result]==0) // If this was the last, decrement the count.
            _rn.differentResults-=1;
    }
    
    /** @dev Give the result of a random number directly (without using commitment).
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
        submission.time=now;
        increaseSubmissionDeposit(rn,submission,msg.value);
        addResult(rn,_result);
        
        return idSubmission;
    }
    

    
    /** @dev Give a commitment of the result.
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
        submission.time=now;
        increaseSubmissionDeposit(rn,submission,msg.value);
        return idSubmission;
    }
    
    /** @dev Reveal your commmitment.
     *  @param _idRN ID of the random number.
     *  @param _idSubmission ID of the submission.
     *  @param _result Result of sequential PoW on the seed.
     */
    function revealResult(uint _idRN, uint _idSubmission, bytes32 _result) {
        RN rn = RNs[_idRN];
        Submission submission=rn.submissions[_idSubmission];
        
        require(rn.startTime+computeMaxTime>now); // Verify submissions are still open.
        require(keccak256(_result,msg.sender)==submission.commitment); // Verify the revealed result match the commitment. Note that this also prevent someone from revealing challenges of other accounts.
        
        addResult(rn,_result);
        submission.result=_result;
    }
    
    /** @dev Challenge a wrong result.
     *  Note that we need _t to be computed offchain because the EVM does not have a logarithm opcode, but have a exponent opcode, making it easy to verify a reult is right.
     *  @param _idRN ID of the random number.
     *  @param _idSubmission ID of the submission.
     *  @return idChallenge The ID of the challenge created.
     */
    function challenge(uint _idRN, uint _idSubmission) payable cost(depositToFee*randomFee) returns (uint idChallenge) {
        RN rn = RNs[_idRN];
        Submission submission=rn.submissions[_idSubmission];
        
        require(rn.startTime+challengeTime>now); // Verify challenges are still open.
        require(!submission.invalidated);
        
        // Create the challenge.
        idChallenge=submission.challenges.length++;
        Challenge challenge=submission.challenges[idChallenge];
        challenge.challenger=msg.sender;
        challenge.beginValue=rn.seed;
        challenge.endValue=submission.result;
        challenge.begin=0;
        challenge.end=rn.difficulty;
        challenge.timeChallenger=currentTotalTimeToRespond;
        challenge.timeSubmitter=currentTotalTimeToRespond;
        challenge.lastInteractionTime=now;
        challenge.deposit=msg.value;
        
        submission.atStakeChallenge+=challenge.deposit;// Increment the number of active challenge for the submission.
        
        return idChallenge;
    }
    
    
    /** @dev Respond to a challenge by giving the medium value.
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
    
    
    /** @dev Continue the challenge in a reduced search space according to the answer of submitter.
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
    
    /** @dev Invalidate a submission.
     *  One fourth is burned.
     *  Three fourth can be claimed by the challengers in proportion of their deposit.
     *  @param _rn Random number of the invalidated submission.
     *  @param _submission The submission which was invalidated.
     */
    function invalidateSubmission(RN storage _rn, Submission storage _submission) internal {
        require(!_submission.invalidated);
        
        _submission.invalidated=true;
        
        // Note that some wei might be lost due to rounding but it is not an issue.
        BURN.transfer(_submission.deposit/4);
        _submission.challengerReward=(3*_submission.deposit)/4;
        removeSubmissionDeposit(_rn,_submission);
        removeResult(_rn,_submission.result);
    }
    
    /** @devInvalidate a challenge.
     *  One fourth is burned.
     *  Transfer three fourth of the challenger deposit to the submitter deposit.
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
        increaseSubmissionDeposit(_rn,_submission,(3*_challenge.deposit)/4);
        BURN.transfer(_challenge.deposit/4);
        _challenge.deposit=0;
    }
    
    /** @dev Finish a challenge, if the challenge is successfull, invalidate the submission, else invalidate the challenge.
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
    
    
    /** @dev Invalidate a submission due to the submitter timing out in one challenge.
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
    
    /** @dev Invalidate a submission the user failed to reveal.
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
    
    /** @dev Time out a challenger.
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
    
    /** @dev Claim the deposit of a challenge back and get a part of the submission deposit.
     *  You can only do it when the challenge is invalidated (no matter who did it).
     *  The amout given is proportional to the deposit you made. Note that splitting equally is not possible because else users would be incentivized in making multiple challenges.
     *  @param _idRN ID of the random number.
     *  @param _idSubmission ID of the submission.
     *  @param _idChallenge ID of the challenge.
     */
    function claimChallengeValue(uint _idRN, uint _idSubmission, uint _idChallenge) {
        RN rn = RNs[_idRN];
        Submission submission=rn.submissions[_idSubmission];
        Challenge challenge=submission.challenges[_idChallenge];
        
        require(!challenge.invalidated);
        require(submission.invalidated);
        require(msg.sender==challenge.challenger);
        require(challenge.deposit!=0);
        
        uint amountToSend=challenge.deposit+((challenge.deposit*submission.challengerReward)/submission.atStakeChallenge);
        challenge.deposit=0;
        challenge.challenger.transfer(amountToSend);
    }
    
    /** @dev Claim the deposit of a submission back and a part of the payout.
     *  @param _idRN ID of the random number.
     *  @param _idSubmission ID of the submission.
     */
    function claimSubmissionValue(uint _idRN, uint _idSubmission) {
        RN rn = RNs[_idRN];
        Submission submission=rn.submissions[_idSubmission];
        
        require(!submission.invalidated);
        require(getRandomValue(_idRN)!=0); // Verify that the random number is determined.
        require(msg.sender==submission.submitter);
        require(submission.deposit!=0); // Verify that the submitter has not already claimed. This prevent the first submitter from keeping calling the contract to get the payout for being the first.
        
        uint submitterPayout=(rn.payout*submission.deposit)/rn.atStakeSubmission; // The part of the payout proportional to the deposit.
        if (rn.firstSubmission==_idSubmission) // If the submitter was the first give him the first submitter reward.
            submitterPayout+=rn.payout;
            
        submission.deposit=0; // The deposit has been claim, but don't update rn.atStakeSubmission in order to make computing parts of the other users simpler.
        submission.submitter.transfer(submitterPayout);
    }
    
    /** @dev Resolve the first submission.
     *  Compute the bonus payout which is 1/3 of the fee and potentially a part of the jackpot proportional to the improvement in time in regard to the target difficulty.
     *  @param _rn The random number structure.
     *  @param _submission The first submission.
     *  @return additionalPayout The additonal amount which should be paid to the firstSubmitter.
     */
    function resolveFirstSubmission(RN storage _rn, Submission storage _submission) internal returns(uint additionalPayout) {
        additionalPayout=_rn.payout; // Count the payout for being the first.
        uint timeFromStart = _submission.time-_rn.startTime; // The time the first submitter took.
        if (_rn.difficulty==currentDifficulty // There hasn't been any difficulty change in between.
            && computeTargetTime > timeFromStart) { // The submission was submitted before the target time. So the submitter will get part of the jackpot.
                additionalPayout+=((computeTargetTime-timeFromStart)*jackpot)/computeTargetTime; // Give a part of the jackpot proportional to the time ahead.
                currentDifficulty=(computeTargetTime*currentDifficulty)/timeFromStart;
                // TODO: Set new difficulty.
            }
        return additionalPayout;
    }
    
    /** @dev Update first submission. This is usefull if the current first submission was invalidated.
     *  @param _idRN ID of the random number.
     */
    function updateFirstSubmission(uint _idRN) {
        RN rn = RNs[_idRN];
        uint8 updateAmount; // Count the number of updates already done.
        while (updateAmount<MAX_FIRST_SUBMISSION_UPDATE 
               && rn.submissions.length > rn.firstSubmission // Make sure firstSubmission is not after the lastSubmission.
               && rn.submissions[rn.firstSubmission].invalidated) {
            rn.firstSubmission+=1;
            updateAmount+=1;
        }
    }
    
    // TODO: Add a way to ask again for a random number if when the challenges are over there is still multiple values.
    
    // Constant functions.
    
    /** @dev Get the random value. Return 0 if the random value is not ready yet.
     *  @param _idRN ID of the random number.
     *  @return randomValue The random value corresponding to the result or 0 if the random number is not available yet.
     */
    function getRandomValue(uint _idRN) constant returns(uint randomValue){
        RN rn = RNs[_idRN];
        if (rn.startTime+challengeTime>now) // There can still be challenges.
            return 0;
        else if (rn.differentResults==0) // All results have been invalidated. It should not happens as long as we have at least one honest party.
            return 0;
        else if (rn.differentResults>1) // There are still multiple competing result, the random number can't be return yet.
            return 0;
        else if (rn.submissions[rn.firstSubmission].invalidated) // The firstSubmission must be updated.
            return 0;
        else
            return uint(rn.submissions[rn.firstSubmission].result);
    }
    
    /** @dev Get a random value specific to the sender. Return 0 if the random value is not ready yet.
     *  This can be used when multiple applications are using the same random number in order to avoid their random numbers to be correlated.
     *  @param _idRN ID of the random number.
     *  @return randomValue The random value corresponding to the result or 0 if the random number is not available yet.
     */
    function getPersonalRandomValue(uint _idRN) constant returns(uint randomValue) {
        uint random = getRandomValue(_idRN);
        if (random==0)
            return 0;
        else
            return uint(keccak256(random,msg.sender));
    }
    
    /** @dev Return your personal commitment of a result.
     *  @param _result The result to commit.
     *  @return hash The commitment (the hash of the value).
     */
    function commitment(bytes32 _result) constant returns(bytes32 hash) {return keccak256(_result,msg.sender);}

    /** @dev Return the time multiplier for a difficulty. It returns the first integer striclty superior to log2(_difficulty).
     *  Note that this function is in O(log(_difficulty))=O(n) where n is the number of bits in the difficulty.
     *  Since the max amount of bits in the difficulty is 255, this function can't cost more than 18000 gas and therefore won't cause out of gas issue.
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

// ATK. Create a lot of randoms such that one is not challenged.
// Solution have one random max asked every hour. Other requests will point to new randoms.

