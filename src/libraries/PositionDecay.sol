pragma solidity ^0.8.7;

// This library contains selected functions from ABDKMath64x64

library PositionDecay {
  /**
   * Calculate negative log2 of x.  Revert if x == 0.
   *
   * @param x UQ0.128 (0 > x > 1.0)
   * @return UQ8.120 (0 > value >=128.0)
   */
  function Log2NegFrac(uint128 x) internal pure returns (uint128) {
    unchecked {
      require(x > 0);

      int256 msb = 0;
      uint256 xc = x;
      if (xc >= 0x10000000000000000) { xc >>= 64; msb += 64; }
      if (xc >= 0x100000000) { xc >>= 32; msb += 32; }
      if (xc >= 0x10000) { xc >>= 16; msb += 16; }
      if (xc >= 0x100) { xc >>= 8; msb += 8; }
      if (xc >= 0x10) { xc >>= 4; msb += 4; }
      if (xc >= 0x4) { xc >>= 2; msb += 2; }
      if (xc >= 0x2) msb += 1;  // No need to shift xc anymore

      int256 result = (msb - 128) << 120;
      uint256 ux = uint256(x) << uint256(127 - msb);
      for (int256 bit = 0x800000000000000000000000000000; bit > 0; bit >>= 1) {
        ux *= ux;
        uint256 b = ux >> 255;
        ux >>= 127 + b;
        result += bit * int256 (b);
      }
  
      return uint128 (uint256(-result));
    }
  }

  /*
   * Maximum value unsigned 128-bit number may have. 
   */
  uint128 private constant MAX_U128 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

  /**
   * Calculate 2^(-xi).  Revert on overflow.
   *
   * @param xi UQ8.120 negative exponent (0 > xi > 129.0)
   * @return UQ0.128 (0 > value > 1.0)
   */
  function Exp2NegFrac(uint128 xi) internal pure returns (uint128) {
    int256 x = -int256(uint256(xi));
    unchecked {
      require (x < 0); // Overflow

      //Todo: evaluate including this check
      //if (x < -0x400000000000000000) return 0; // Underflow

      uint256 result = 0x80000000000000000000000000000000;

      if (x & 2**119 > 0)
        result += result * 0xd413cccfe779921165f626cdd52afa7c >> 129;
      if (x & 2**118 > 0)
        result += result * 0xc1bf828c6dc54b7a356918c17217b7b3 >> 130;
      if (x & 2**117 > 0)
        result += result * 0xb95c1e3ea8bd6e6fbe4628758a53c902 >> 131;
      if (x & 2**116 > 0)
        result += result * 0xb5586cf9890f6298b92b71842a983643 >> 132;
      if (x & 2**115 > 0)
        result += result * 0xb361a62b0ae875cf8a91d6d19482ffca >> 133;
      if (x & 2**114 > 0)
        result += result * 0xb268f9de0183b9bdf2b293de8a6f7a4f >> 134;
      if (x & 2**113 > 0)
        result += result * 0xb1ed4fd999ab6c25335719b6e6fd2002 >> 135;
      if (x & 2**112 > 0)
        result += result * 0xb1afa5abcbed6129ab13ec11dc954456 >> 136;
      if (x & 2**111 > 0)
        result += result * 0xb190db43813d43fe33a5299e5ecf38d1 >> 137;
      if (x & 2**110 > 0)
        result += result * 0xb18178ba33b141b486ff22688e804202 >> 138;
      if (x & 2**109 > 0)
        result += result * 0xb179c82028fd0945e54e2ae18f2f036f >> 139;
      if (x & 2**108 > 0)
        result += result * 0xb175effdc76ba38e31671ca939726694 >> 140;
      if (x & 2**107 > 0)
        result += result * 0xb17403f73f2dad959a9630122f87c875 >> 141;
      if (x & 2**106 > 0)
        result += result * 0xb1730df6a5247426170d231a39ecf541 >> 142;
      if (x & 2**105 > 0)
        result += result * 0xb17292f702a3aa22beacca9490136cea >> 143;
      if (x & 2**104 > 0)
        result += result * 0xb17255775c040618bf4a4ade83fca8f9 >> 144;
      if (x & 2**103 > 0)
        result += result * 0xb17236b7935c5ddb03d36fa99f583637 >> 145;
      if (x & 2**102 > 0)
        result += result * 0xb1722757b1b2935f22b3005edf276738 >> 146;
      if (x & 2**101 > 0)
        result += result * 0xb1721fa7c188307016c1cd4e8b6b7d9a >> 147;
      if (x & 2**100 > 0)
        result += result * 0xb1721bcfc99d9f890ea069117637d191 >> 148;
      if (x & 2**99 > 0)
        result += result * 0xb17219e3cdb2ff39429b7982c513f4ec >> 149;
      if (x & 2**98 > 0)
        result += result * 0xb17218edcfc0591a3daeb1728b047db6 >> 150;
      if (x & 2**97 > 0)
        result += result * 0xb1721872d0c7b08cf1e0114152fb8796 >> 151;
      if (x & 2**96 > 0)
        result += result * 0xb1721835514b86e6d96efd1bff6819e4 >> 152;
      if (x & 2**95 > 0)
        result += result * 0xb1721816918d7cbbf08d8b65e0592b47 >> 153;
      if (x & 2**94 > 0)
        result += result * 0xb172180731ae7a5084f1c9cdeaffbc3a >> 154;
      if (x & 2**93 > 0)
        result += result * 0xb17217ff81bef9c551590cf835d529e4 >> 155;
      if (x & 2**92 > 0)
        result += result * 0xb17217fba9c739aa5819f44f9c7fa9ee >> 156;
      if (x & 2**91 > 0)
        result += result * 0xb17217f9bdcb59a7839db9047620caf6 >> 157;
      if (x & 2**90 > 0)
        result += result * 0xb17217f8c7cd69a8c3686f943f43d1fd >> 158;
      if (x & 2**89 > 0)
        result += result * 0xb17217f84cce71aa0dcfffe7dd41e2f1 >> 159;
      if (x & 2**88 > 0)
        result += result * 0xb17217f80f4ef5aadda4555466e70cc0 >> 160;
      if (x & 2**87 > 0)
        result += result * 0xb17217f7f08f37ab5036a35b53ec89bd >> 161;
      if (x & 2**86 > 0)
        result += result * 0xb17217f7e12f58ab8c29d332f3ad2e39 >> 162;
      if (x & 2**85 > 0)
        result += result * 0xb17217f7d97f692baacded53cdc31f75 >> 163;
      if (x & 2**84 > 0)
        result += result * 0xb17217f7d5a7716bba4a9af17d584482 >> 164;
      if (x & 2**83 > 0)
        result += result * 0xb17217f7d3bb758bc21399e3a5c4fabb >> 165;
      if (x & 2**82 > 0)
        result += result * 0xb17217f7d2c5779bc5fac3658e23d1d6 >> 166;
      if (x & 2**81 > 0)
        result += result * 0xb17217f7d24a78a3c7ef02a8b75d5ac6 >> 167;
      if (x & 2**80 > 0)
        result += result * 0xb17217f7d20cf927c8e94cead93ca663 >> 168;
      if (x & 2**79 > 0)
        result += result * 0xb17217f7d1ee3969c9667cb40d7cedf4 >> 169;
      if (x & 2**78 > 0)
        result += result * 0xb17217f7d1ded98ac9a51742b0713a2d >> 170;
      if (x & 2**77 > 0)
        result += result * 0xb17217f7d1d7299b49c4653484206a65 >> 171;
      if (x & 2**76 > 0)
        result += result * 0xb17217f7d1d351a389d40c580e854508 >> 172;
      if (x & 2**75 > 0)
        result += result * 0xb17217f7d1d165a7a9dbdff47bdb02fb >> 173;
      if (x & 2**74 > 0)
        result += result * 0xb17217f7d1d06fa9b9dfc9c55c8eb61d >> 174;
      if (x & 2**73 > 0)
        result += result * 0xb17217f7d1cff4aac1e1beae776ac4b8 >> 175;
      if (x & 2**72 > 0)
        result += result * 0xb17217f7d1cfb72b45e2b9232f795948 >> 176;
      if (x & 2**71 > 0)
        result += result * 0xb17217f7d1cf986b87e3365d9628c6e1 >> 177;
      if (x & 2**70 > 0)
        result += result * 0xb17217f7d1cf890ba8e374facc2a8681 >> 178;
      if (x & 2**69 > 0)
        result += result * 0xb17217f7d1cf815bb963944967d5e887 >> 179;
      if (x & 2**68 > 0)
        result += result * 0xb17217f7d1cf7d83c1a3a3f0b5d63a17 >> 180;
      if (x & 2**67 > 0)
        result += result * 0xb17217f7d1cf7b97c5c3abc45ce10b02 >> 181;
      if (x & 2**66 > 0)
        result += result * 0xb17217f7d1cf7aa1c7d3afae30691d80 >> 182;
      if (x & 2**65 > 0)
        result += result * 0xb17217f7d1cf7a26c8dbb1a31a2dd142 >> 183;
      if (x & 2**64 > 0)
        result += result * 0xb17217f7d1cf79e9495fb29d8f1055c3 >> 184;
      if (x & 2**63 > 0)
        result += result * 0xb17217f7d1cf79ca89a1b31ac981a2ac >> 185;
      if (x & 2**62 > 0)
        result += result * 0xb17217f7d1cf79bb29c2b35966ba4bca >> 186;
      if (x & 2**61 > 0)
        result += result * 0xb17217f7d1cf79b379d33378b556a104 >> 187;
      if (x & 2**60 > 0)
        result += result * 0xb17217f7d1cf79afa1db73885ca4cbcb >> 188;
      if (x & 2**59 > 0)
        result += result * 0xb17217f7d1cf79adb5df9390304be13a >> 189;
      if (x & 2**58 > 0)
        result += result * 0xb17217f7d1cf79acbfe1a3941a1f6bf4 >> 190;
      if (x & 2**57 > 0)
        result += result * 0xb17217f7d1cf79ac44e2ab960f093151 >> 191;
      if (x & 2**56 > 0)
        result += result * 0xb17217f7d1cf79ac07632f97097e1400 >> 192;
      if (x & 2**55 > 0)
        result += result * 0xb17217f7d1cf79abe8a3719786b88558 >> 193;
      if (x & 2**54 > 0)
        result += result * 0xb17217f7d1cf79abd9439297c555be03 >> 194;
      if (x & 2**53 > 0)
        result += result * 0xb17217f7d1cf79abd193a317e4a45a59 >> 195;
      if (x & 2**52 > 0)
        result += result * 0xb17217f7d1cf79abcdbbab57f44ba884 >> 196;
      if (x & 2**51 > 0)
        result += result * 0xb17217f7d1cf79abcbcfaf77fc1f4f9a >> 197;
      if (x & 2**50 > 0)
        result += result * 0xb17217f7d1cf79abcad9b18800092325 >> 198;
      if (x & 2**49 > 0)
        result += result * 0xb17217f7d1cf79abca5eb29001fe0cea >> 199;
      if (x & 2**48 > 0)
        result += result * 0xb17217f7d1cf79abca21331402f881cd >> 200;
      if (x & 2**47 > 0)
        result += result * 0xb17217f7d1cf79abca0273560375bc3e >> 201;
      if (x & 2**46 > 0)
        result += result * 0xb17217f7d1cf79abc9f3137703b45977 >> 202;
      if (x & 2**45 > 0)
        result += result * 0xb17217f7d1cf79abc9eb638783d3a813 >> 203;
      if (x & 2**44 > 0)
        result += result * 0xb17217f7d1cf79abc9e78b8fc3e34f61 >> 204;
      if (x & 2**43 > 0)
        result += result * 0xb17217f7d1cf79abc9e59f93e3eb2308 >> 205;
      if (x & 2**42 > 0)
        result += result * 0xb17217f7d1cf79abc9e4a995f3ef0cdc >> 206;
      if (x & 2**41 > 0)
        result += result * 0xb17217f7d1cf79abc9e42e96fbf101c5 >> 207;
      if (x & 2**40 > 0)
        result += result * 0xb17217f7d1cf79abc9e3f1177ff1fc3a >> 208;
      if (x & 2**39 > 0)
        result += result * 0xb17217f7d1cf79abc9e3d257c1f27975 >> 209;
      if (x & 2**38 > 0)
        result += result * 0xb17217f7d1cf79abc9e3c2f7e2f2b812 >> 210;
      if (x & 2**37 > 0)
        result += result * 0xb17217f7d1cf79abc9e3bb47f372d761 >> 211;
      if (x & 2**36 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b76ffbb2e708 >> 212;
      if (x & 2**35 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b583ffd2eedc >> 213;
      if (x & 2**34 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b48e01e2f2c5 >> 214;
      if (x & 2**33 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b41302eaf4ba >> 215;
      if (x & 2**32 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b3d5836ef5b5 >> 216;
      if (x & 2**31 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b3b6c3b0f632 >> 217;
      if (x & 2**30 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b3a763d1f671 >> 218;
      if (x & 2**29 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b39fb3e27690 >> 219;
      if (x & 2**28 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b39bdbeab6a0 >> 220;
      if (x & 2**27 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b399efeed6a7 >> 221;
      if (x & 2**26 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b398f9f0e6ab >> 222;
      if (x & 2**25 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b3987ef1eead >> 223;
      if (x & 2**24 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b398417272ae >> 224;
      if (x & 2**23 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b39822b2b4af >> 225;
      if (x & 2**22 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b3981352d5af >> 226;
      if (x & 2**21 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b3980ba2e62f >> 227;
      if (x & 2**20 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b39807caee6f >> 228;
      if (x & 2**19 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b39805def28f >> 229;
      if (x & 2**18 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b39804e8f49f >> 230;
      if (x & 2**17 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b398046df5a7 >> 231;
      if (x & 2**16 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b3980430762b >> 232;
      if (x & 2**15 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b3980411b66d >> 233;
      if (x & 2**14 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b3980402568e >> 234;
      if (x & 2**13 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b39803faa69f >> 235;
      if (x & 2**12 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b39803f6cea7 >> 236;
      if (x & 2**11 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b39803f4e2ab >> 237;
      if (x & 2**10 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b39803f3ecad >> 238;
      if (x & 2**9 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b39803f371ae >> 239;
      if (x & 2**8 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b39803f3342f >> 240;
      if (x & 2**7 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b39803f3156f >> 241;
      if (x & 2**6 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b39803f3060f >> 242;
      if (x & 2**5 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b39803f2fe5f >> 243;
      if (x & 2**4 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b39803f2fa87 >> 244;
      if (x & 2**3 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b39803f2f89b >> 245;
      if (x & 2**2 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b39803f2f7a5 >> 246;
      if (x & 2**1 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b39803f2f72a >> 247;
      if (x & 2**0 > 0)
        result += result * 0xb17217f7d1cf79abc9e3b39803f2f6ed >> 248;

      result >>= uint256 (int256 (-1 - (x >> 120)));
      require (result <= uint256 (MAX_U128));

      return uint128 (result);
    }
  }
}