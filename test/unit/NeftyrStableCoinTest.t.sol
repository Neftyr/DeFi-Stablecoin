// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {NeftyrStableCoin} from "../../src/NeftyrStableCoin.sol";
import {Test, console} from "forge-std/Test.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

contract NeftyrStableCoinTest is StdCheats, Test {
    NeftyrStableCoin nfr;

    function setUp() public {
        nfr = new NeftyrStableCoin();
    }

    function testConstructorSetsCorrectNameAndSymbol() public {
        string memory nfrName = nfr.name();
        string memory nfrSymbol = nfr.symbol();

        console.log("Coin Name: ", nfrName);
        console.log("Coin Symbol: ", nfrSymbol);

        assertEq(nfrName, "Neftyr");
        assertEq(nfrSymbol, "NFR");
    }

    function testRevertsIfBurnZero() public {
        nfr.mint(address(this), 100);

        vm.expectRevert(NeftyrStableCoin.NeftyrStableCoin__NotEnoughTokensAmount.selector);
        nfr.burn(0);
    }

    function testRevertsIfBurnMoreThanYouHave() public {
        nfr.mint(address(this), 100);

        vm.expectRevert(NeftyrStableCoin.NeftyrStableCoin__BurnAmountExceedsBalance.selector);
        nfr.burn(101);
    }

    function testCanBurnNFR() public {
        nfr.mint(address(this), 100);

        nfr.burn(100);
    }

    function testRevertsIfMintToZeroAddress() public {
        vm.expectRevert(NeftyrStableCoin.NeftyrStableCoin__ZeroAddress.selector);
        nfr.mint(address(0), 100);
    }

    function testRevertsIfMintZero() public {
        vm.expectRevert(NeftyrStableCoin.NeftyrStableCoin__NotEnoughTokensAmount.selector);
        nfr.mint(address(this), 0);
    }

    function testCanMintNFR() public {
        nfr.mint(address(this), 100);

        uint256 balance = nfr.balanceOf(address(this));

        assert(balance == 100);
    }
}
