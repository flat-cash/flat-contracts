// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../src/vault/FlatIDVaultV4.sol";

/// @dev Minimal HEVM cheatcode interface (no forge-std dependency).
interface Vm {
    function warp(uint256 newTimestamp) external;
    function prank(address msgSender) external;
    function expectRevert() external;
    function expectRevert(bytes4 revertData) external;
}

address constant HEVM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) { name = n; symbol = s; }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Minimal ERC-4626 mock with a ratcheting-up exchange rate.
contract MockSFlatVault is MockERC20 {
    MockERC20 public immutable asset;

    constructor(address _asset) MockERC20("Savings FLAT", "sFLAT") {
        asset = MockERC20(_asset);
    }

    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return assets;
        return assets * supply / totalAssets();
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return shares;
        return shares * totalAssets() / supply;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        require(shares > 0, "zero shares");
        require(asset.transferFrom(msg.sender, address(this), assets), "transfer");
        totalSupply += shares;
        balanceOf[receiver] += shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        if (msg.sender != owner) {
            require(allowance[owner][msg.sender] >= shares, "allow");
            allowance[owner][msg.sender] -= shares;
        }
        assets = convertToAssets(shares);
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        require(asset.transfer(receiver, assets), "transfer");
    }

    function accrue(uint256 amount) external {
        require(asset.transferFrom(msg.sender, address(this), amount), "transfer");
    }
}

contract FlatIDVaultV4Test {
    Vm constant vm = Vm(HEVM_ADDRESS);
    uint256 constant E18 = 1e18;
    uint256 constant DAY = 1 days;
    uint256 constant HEARTBEAT = 60 days;

    MockERC20 flat;
    MockERC20 save;
    MockSFlatVault sflat;
    FlatIDVaultV4 vault;

    address admin = address(0xA);
    address operator = address(0xB);
    address guardian = address(0xC);
    address alice = address(0x1);
    address bob = address(0x2);
    address carol = address(0x3);
    address rando = address(0x4);

    function setUp() public {
        flat = new MockERC20("FLAT", "FLAT");
        save = new MockERC20("SAVE", "SAVE");
        sflat = new MockSFlatVault(address(flat));
        vault = new FlatIDVaultV4(
            address(flat), address(save), address(sflat),
            admin, operator, guardian, HEARTBEAT, 7 days
        );
    }

    // ── 1. Heartbeat authorization matrix ────────────────────────────────
    function testHeartbeatCallers() public {
        vm.prank(admin); vault.heartbeat();
        vm.prank(operator); vault.heartbeat();
        vm.prank(guardian); vault.heartbeat();
        vm.prank(rando); vm.expectRevert(); vault.heartbeat();
    }

    function testHeartbeatDisabledAfterAbandonment() public {
        vm.warp(block.timestamp + HEARTBEAT + 1);
        vm.prank(admin); vm.expectRevert(); vault.heartbeat();
        vm.prank(operator); vm.expectRevert(); vault.heartbeat();
        vm.prank(guardian); vm.expectRevert(); vault.heartbeat();
    }

    // ── 2. Deposit solvency + principal ──────────────────────────────────
    function testRecordDepositSolvency() public {
        flat.mint(address(vault), 1000 * E18);
        vm.prank(operator); vm.expectRevert(); // beyond holdings
        vault.recordDeposit(address(flat), alice, 1001 * E18);
        vm.prank(operator);
        vault.recordDeposit(address(flat), alice, 500 * E18);
        (uint256 total,,,,,,) = vault.lanes(address(flat));
        assertEq(total, 500 * E18, "lane total");
        assertEq(vault.principalOf(address(flat), alice), 500 * E18, "principal");
    }

    // ── 3. Per-lane operator caps ────────────────────────────────────────
    function testPerLaneSettleCap() public {
        flat.mint(address(vault), 1000 * E18);
        vm.prank(operator); vault.recordDeposit(address(flat), alice, 500 * E18);
        vm.prank(operator); vault.recordDeposit(address(flat), bob, 200 * E18);
        vm.prank(admin); vault.setLaneSettlePrincipalLimit(address(flat), 300 * E18);

        vm.prank(operator); vault.settleTransfer(address(flat), alice, bob, 250 * E18);
        assertEq(vault.principalOf(address(flat), bob), 450 * E18, "principal moved");

        vm.prank(operator); vm.expectRevert(); // 250 + 100 > 300 cap
        vault.settleTransfer(address(flat), alice, bob, 100 * E18);

        // admin exempt
        vm.prank(admin); vault.settleTransfer(address(flat), alice, bob, 100 * E18);
    }

    function testPerLaneCapsIndependent() public {
        flat.mint(address(vault), 1000 * E18);
        save.mint(address(vault), 100 * E18);
        vm.prank(operator); vault.recordDeposit(address(flat), alice, 500 * E18);
        vm.prank(operator); vault.recordDeposit(address(save), carol, 100 * E18);
        vm.prank(admin); vault.setLaneWithdrawLimit(address(flat), 50 * E18);

        vm.prank(operator); vault.withdraw(address(flat), alice, 40 * E18);
        vm.prank(operator); vm.expectRevert(); // FLAT lane cap exhausted
        vault.withdraw(address(flat), alice, 20 * E18);

        // SAVE lane unaffected
        vm.prank(operator); vault.withdraw(address(save), carol, 100 * E18);
        assertEq(save.balanceOf(carol), 100 * E18, "SAVE lane independent");
    }

    // ── 4. sFLAT round-trip with rising factor ───────────────────────────
    function testSflatRoundTrip() public {
        flat.mint(address(vault), 1000 * E18);
        vm.prank(operator); vault.recordDeposit(address(flat), alice, 500 * E18);
        vm.prank(operator); vault.convertFlatToSflat(alice, 200 * E18, 1);
        uint256 sh = vault.userBalances(address(sflat), alice);
        assertGt(sh, 0, "shares credited");

        // lane solvency after conversion
        (uint256 flatClaims,,,,,,) = vault.lanes(address(flat));
        assertGe(flat.balanceOf(address(vault)), flatClaims, "FLAT lane solvent");
        (uint256 shClaims,,,,,,) = vault.lanes(address(sflat));
        assertGe(sflat.balanceOf(address(vault)), shClaims, "sFLAT lane solvent");

        // yield accrues -> rate up
        flat.mint(address(this), 10 * E18);
        flat.approve(address(sflat), 10 * E18);
        sflat.accrue(10 * E18);

        uint256 preview = sflat.convertToAssets(sh);
        (uint256 flatBefore,,,,,,) = vault.lanes(address(flat));
        flatBefore = vault.userBalances(address(flat), alice);
        vm.prank(operator); vault.convertSflatToFlat(alice, sh, 1);
        uint256 gained = vault.userBalances(address(flat), alice) - flatBefore;
        assertGe(gained, preview, "payout >= display");
        assertGt(gained, sh, "yield captured");
    }

    // ── 5. Seed + finalize ───────────────────────────────────────────────
    function testSeedFinalize() public {
        save.mint(address(vault), 1188.62 ether);
        address[] memory users = new address[](1);
        uint256[] memory amts = new uint256[](1);
        users[0] = carol; amts[0] = 1188.62 ether;
        vm.prank(admin); vault.seedBalances(address(save), users, amts);
        vm.prank(admin); vault.finalizeSeed();
        assertTrue(vault.seedingComplete(), "sealed");
        vm.prank(admin); vm.expectRevert(); // seed dead after finalize
        vault.seedBalances(address(save), users, amts);
    }

    function testFinalizeSeedRevertsIfUnderfunded() public {
        address[] memory users = new address[](1);
        uint256[] memory amts = new uint256[](1);
        users[0] = carol; amts[0] = 100 * E18;
        vm.prank(admin); vault.seedBalances(address(save), users, amts);
        vm.prank(admin); vm.expectRevert(); // vault holds no SAVE
        vault.finalizeSeed();
    }

    // ── 6. Abandonment: emergencyWithdraw + recoverSurplus ───────────────
    function testEmergencyWithdrawAfterAbandonment() public {
        flat.mint(address(vault), 1000 * E18);
        flat.mint(address(vault), 100 * E18); // surplus
        vm.prank(operator); vault.recordDeposit(address(flat), alice, 500 * E18);

        vm.warp(block.timestamp + HEARTBEAT + 1);
        assertTrue(vault.isAbandoned(), "abandoned");

        vm.prank(rando); vm.expectRevert(); // no claim
        vault.emergencyWithdraw(address(flat));

        vm.prank(alice);
        vault.emergencyWithdraw(address(flat));
        assertEq(flat.balanceOf(alice), 500 * E18, "alice recovered principal");
    }

    function testRecoverSurplusTimelockAndCap() public {
        flat.mint(address(vault), 1100 * E18);
        vm.prank(operator); vault.recordDeposit(address(flat), alice, 500 * E18);

        uint256 t0 = block.timestamp;
        vm.warp(t0 + HEARTBEAT + 1);

        vm.prank(guardian); vm.expectRevert(); // before 30-day timelock
        vault.recoverSurplus(address(flat));

        vm.warp(t0 + HEARTBEAT + 1 + 30 days);
        vm.prank(rando); vm.expectRevert(); // non-guardian
        vault.recoverSurplus(address(flat));

        uint256 pre = flat.balanceOf(guardian);
        vm.prank(guardian); vault.recoverSurplus(address(flat));
        assertEq(flat.balanceOf(guardian) - pre, 600 * E18, "surplus = balance - claims");

        // user claims remain withdrawable after surplus recovery
        vm.prank(alice); vault.emergencyWithdraw(address(flat));
        assertEq(flat.balanceOf(alice), 500 * E18, "claims untouchable");
    }

    // ── 7. Revive: one-time, 7-day timelock ──────────────────────────────
    function testReviveOneTime() public {
        uint256 t0 = block.timestamp;
        vm.warp(t0 + HEARTBEAT + 1);

        vm.prank(guardian); vm.expectRevert(); // not queued
        vault.revive();

        vm.prank(guardian); vault.queueRevive();
        vm.prank(guardian); vm.expectRevert(); // timelock
        vault.revive();

        vm.warp(t0 + HEARTBEAT + 1 + 7 days + 1);
        vm.prank(guardian); vault.revive();
        assertTrue(!vault.isAbandoned(), "revived");
        assertTrue(vault.revived(), "spent");

        vm.prank(admin); vault.heartbeat(); // works again

        // second abandonment is final
        vm.warp(block.timestamp + HEARTBEAT + 1);
        vm.prank(guardian); vm.expectRevert();
        vault.queueRevive();
    }

    // ── 8. Pause gating ──────────────────────────────────────────────────
    function testPauseGating() public {
        flat.mint(address(vault), 100 * E18);
        vm.prank(operator); vault.recordDeposit(address(flat), alice, 100 * E18);

        vm.prank(guardian); vault.pause();
        vm.prank(operator); vm.expectRevert();
        vault.settleTransfer(address(flat), alice, bob, 1);
        vm.prank(operator); vm.expectRevert();
        vault.convertFlatToSflat(alice, 1, 1);

        vm.prank(guardian); vault.unpause();
        vm.prank(guardian); vm.expectRevert(); // re-pause cooldown
        vault.pause();
    }

    // ── assertions ───────────────────────────────────────────────────────
    function assertEq(uint256 a, uint256 b, string memory m) internal pure {
        require(a == b, string.concat("assertEq: ", m));
    }
    function assertGe(uint256 a, uint256 b, string memory m) internal pure {
        require(a >= b, string.concat("assertGe: ", m));
    }
    function assertGt(uint256 a, uint256 b, string memory m) internal pure {
        require(a > b, string.concat("assertGt: ", m));
    }
    function assertTrue(bool c, string memory m) internal pure {
        require(c, string.concat("assertTrue: ", m));
    }
}
