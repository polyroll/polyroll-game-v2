// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IMiner {
    function recordReferrer(address _user, address _referrer) external;
    function addReward(address _user, uint _amount) external;
}