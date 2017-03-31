pragma solidity ^0.4.10;

contract LowInfluenceRNG {
    /** @notice Return a random number using a low influence function on the _nbBlocks blockhashes starting from _startBlock with _nbBit of randomness.
    *   @param _startBlock First block to be used.
    *   @param _nbBlock Number of blocks to be used. Maximum is 255 but it is advised to put a lower value to deal with the time for your transaction being included.
    *   @param _nbBit Number of bits of randomness. Maximum is 31. If you don't hash it, you must use a odd number, else zeros will be more likely than ones.
    *   @return random The random number or 0 if there is an error.
    **/
    function getRandom(uint256 _startBlock, uint8 _nbBlock, uint8 _nbBit) constant returns (uint256 random) {
        if (block.blockhash(_startBlock) == 0)
            return 0; // It's too late to get the random number, you can only get the 256 last.
        if (block.blockhash(_startBlock+_nbBlock-1) == 0)
            return 0; // You haven't waited enough, the last block is not published yet.
        if (_nbBit>32)
            return 0; // Only work up to 32 bit of randomness (which will be enough for most applications).
            
        uint8[32] memory oneCount; // Note that it is cheaper to assign the max value instead of assigning dynamically.
        uint8 threshold = _nbBlock/2;
        uint256 result=0;
        uint256 mask=1; // Start at 0....01.
        
        // Set oneCount to the number of odd bytes for each byte.
        for (uint256 i=_startBlock;i<_startBlock+_nbBlock;++i){
            bytes32 b = block.blockhash(i);
            for (uint8 j=0;j<_nbBit;++j)
                oneCount[j]+=uint8(b[j] & 1); // Add 1 if the byte is odd.
        }
        
        // Set oneCount to 1 if there are more 1 than 0 for each byte.
        for (j=0;j<_nbBit;++j) // Put to 1 if above threshold, 0 therwise.
        {
            if (oneCount[j]>threshold)
                result+=mask;
            mask*=2; // Shift the 1 to the left.
        }
        

        return result; 
        
    }
    
    /** @notice Same as getRandom but hash the result such that 1 bit change changes the whole result.
     *   @param _startBlock First block to be used.
     *   @param _nbBlock Number of blocks to be used. Maximum is 255 but it is advised to put a lower value to deal with the time for your transaction being included.
     *   @param _nbBit Number of bits of randomness. Maximum is 31. If you don't hash it, you must use a odd number, else zeros will be more likely than ones.
     *   @return random The random number or 0 if there is an error. 
     **/
    function getHashedRandom(uint256 _startBlock, uint8 _nbBlock, uint8 _nbBit) constant returns (uint256 random) {
        return uint256(keccak256(getRandom(_startBlock, _nbBlock, _nbBit))); // Hash everything to make a change of 1 bit change the whole result.
    }
    
    /** @notice Same as getHashedRandom but also hash with msg.sender to avoid random number to be the same for different contracts.
     *   @param _startBlock First block to be used.
     *   @param _nbBlock Number of blocks to be used. Maximum is 255 but it is advised to put a lower value to deal with the time for your transaction being included.
     *   @param _nbBit Number of bits of randomness. Maximum is 31. If you don't hash it, you must use a odd number, else zeros will be more likely than ones.
     *   @return random The random number or 0 if there is an error. 
     **/
    function getHashedUncorrelatedRandom(uint256 _startBlock, uint8 _nbBlock, uint8 _nbBit) constant returns (uint256 random) {
        return uint256(keccak256(getRandom(_startBlock, _nbBlock, _nbBit),msg.sender));
    }

    function testGas(uint256 _startBlock, uint8 _nbBlock, uint8 _nbBit) returns (uint256 random) {
        return uint256(keccak256(getRandom(_startBlock, _nbBlock, _nbBit),msg.sender));
    }
}


