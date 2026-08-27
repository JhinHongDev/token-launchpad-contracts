// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Clones as OurClones} from "src/Clones.sol";
import {Clones as OzClones} from "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";

contract ProbeTarget {
    uint256 public x = 1;
}

/// @dev 库内部一致性微探针：同一调用方、同一盐下 create2 实际落位 vs 预言公式（我方 vs OZ）
library LibProbe {
    function probe(address impl, bytes32 salt)
        external
        returns (
            address ourActual,
            address ourPredicted,
            address ozActual,
            address ozPredicted
        )
    {
        ourActual = OurClones.cloneDeterministic(impl, salt);
        ourPredicted = OurClones.predictDeterministicAddress(impl, salt, address(this));
        // OZ 路径换一个盐避免地址冲突
        ozActual = OzClones.cloneDeterministic(impl, bytes32(uint256(salt) ^ uint256(1)));
        ozPredicted = OzClones.predictDeterministicAddress(impl, bytes32(uint256(salt) ^ uint256(1)), address(this));
    }
}

contract AsmProbeTest is Test {
    /// @dev 四方对照：我方库 create2 实际落位 == 我方预言；OZ 路径自洽且与我方语义一致
    function test_Probe() public {
        ProbeTarget t = new ProbeTarget();
        (address oA, address oP, address zA, address zP) =
            LibProbe.probe(address(t), keccak256("probe"));
        emit log_named_address("ourActual   ", oA);
        emit log_named_address("ourPredicted", oP);
        emit log_named_address("ozActual    ", zA);
        emit log_named_address("ozPredicted ", zP);
        assertEq(zA, zP, "OZ internal parity must hold");
        assertEq(oA, oP, "OURS must equal OZ semantics");
    }
}
