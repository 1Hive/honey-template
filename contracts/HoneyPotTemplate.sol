pragma solidity 0.4.24;

import "@aragon/templates-shared/contracts/BaseTemplate.sol";
import {IHookedTokenManager as HookedTokenManager} from "./external/IHookedTokenManager.sol";
import {IIssuance as Issuance} from "./external/IIssuance.sol";
import {ITollgate as Tollgate} from "./external/ITollgate.sol";
import {IConvictionVoting as ConvictionVoting} from "./external/IConvictionVoting.sol";
import "@1hive/apps-brightid-register/contracts/BrightIdRegister.sol";
import "./external/Agreement.sol";
import "./external/DisputableVoting.sol";

contract HoneyPotTemplate is BaseTemplate {

    string constant private ERROR_MISSING_MEMBERS = "MISSING_MEMBERS";
    string constant private ERROR_BAD_VOTE_SETTINGS = "BAD_SETTINGS";
    string constant private ERROR_NO_CACHE = "NO_CACHE";
    string constant private ERROR_NO_TOLLGATE_TOKEN = "NO_TOLLGATE_TOKEN";

    // rinkeby
     bytes32 private constant CONVICTION_VOTING_APP_ID = keccak256(abi.encodePacked(apmNamehash("open"), keccak256("disputable-conviction-voting")));
     bytes32 private constant HOOKED_TOKEN_MANAGER_APP_ID = keccak256(abi.encodePacked(apmNamehash("open"), keccak256("gardens-token-manager")));
     bytes32 private constant DYNAMIC_ISSUANCE_APP_ID = keccak256(abi.encodePacked(apmNamehash("open"), keccak256("dynamic-issuance")));
     bytes32 private constant BRIGHTID_REGISTER_APP_ID = keccak256(abi.encodePacked(apmNamehash("open"), keccak256("brightid-register")));
     bytes32 private constant AGREEMENT_APP_ID = 0x41dd0b999b443a19321f2f34fe8078d1af95a1487b49af4c2ca57fb9e3e5331e; // agreement-1hive.open.aragonpm.eth
     bytes32 private constant DISPUTABLE_VOTING_APP_ID = 0x39aa9e500efe56efda203714d12c78959ecbf71223162614ab5b56eaba014145; // probably disputable-voting.open.aragonpm.eth

    // xdai // TODO: Remove the Change Controller Permission
//    bytes32 private constant CONVICTION_VOTING_APP_ID = keccak256(abi.encodePacked(apmNamehash("1hive"), keccak256("conviction-voting")));
//    bytes32 private constant HOOKED_TOKEN_MANAGER_APP_ID = keccak256(abi.encodePacked(apmNamehash("1hive"), keccak256("token-manager")));
//    bytes32 private constant DYNAMIC_ISSUANCE_APP_ID = keccak256(abi.encodePacked(apmNamehash("1hive"), keccak256("issuance")));

    uint256 private constant VAULT_INITIAL_FUNDS = 1000e18;
    bool private constant TOKEN_TRANSFERABLE = true;
    uint8 private constant TOKEN_DECIMALS = uint8(18);
    uint256 private constant TOKEN_MAX_PER_ACCOUNT = uint256(-1);
    address private constant ANY_ENTITY = address(-1);
    uint8 private constant ORACLE_PARAM_ID = 203;
    enum Op { NONE, EQ, NEQ, GT, LT, GTE, LTE, RET, NOT, AND, OR, XOR, IF_ELSE }

    struct DeployedContracts {
        Kernel dao;
        ACL acl;
        DisputableVoting disputableVoting;
        Vault fundingPoolVault;
        HookedTokenManager hookedTokenManager;
        Issuance issuance;
        MiniMeToken voteToken;
        ConvictionVoting convictionVoting;
    }

    event DisputableVotingAddress(DisputableVoting disputableVoting);
    event VoteToken(MiniMeToken voteToken);
    event VaultAddress(Vault vaultAddress);
    event AgentAddress(Agent agentAddress);
    event HookedTokenManagerAddress(HookedTokenManager hookedTokenManagerAddress);
    event ConvictionVotingAddress(ConvictionVoting convictionVoting);
    event BrightIdRegisterAddress(BrightIdRegister brightIdRegister);
    event AgreementAddress(Agreement agreement);

    mapping(address => DeployedContracts) internal senderDeployedContracts;

    constructor(DAOFactory _daoFactory, ENS _ens, MiniMeTokenFactory _miniMeFactory, IFIFSResolvingRegistrar _aragonID)
        BaseTemplate(_daoFactory, _ens, _miniMeFactory, _aragonID) public
    {
        _ensureAragonIdIsValid(_aragonID);
        _ensureMiniMeFactoryIsValid(_miniMeFactory);
    }

    // New DAO functions //

    /**
    * @dev Create the DAO and initialise the basic apps necessary for gardens
    * @param _disputableVotingSettings Array of [voteDuration, voteSupportRequired, voteMinAcceptanceQuorum, voteDelegatedVotingPeriod,
    *    voteQuietEndingPeriod, voteQuierEndingExtension, voteExecutionDelay] to set up the voting app of the organization
    */
    function createDaoTxOne(
        MiniMeToken _voteToken,
        uint64[7] _disputableVotingSettings,
        bytes32 _1hiveContext,
        address[] _verifiers,
        uint256[3] _brightIdSettings
    )
        public // Increases stack limit over using external
    {
        require(_disputableVotingSettings.length == 7, ERROR_BAD_VOTE_SETTINGS);

        (Kernel dao, ACL acl) = _createDAO();
        Vault fundingPoolVault = _installVaultApp(dao);
        Agent agent = _installDefaultAgentApp(dao);

        MiniMeToken voteToken = _voteToken;
        if (address(_voteToken) == address(0)) {
            voteToken = _createToken("Honey", "HNY", TOKEN_DECIMALS);
            voteToken.changeController(msg.sender);
        }

        DisputableVoting disputableVoting = _installDisputableVotingApp(dao, voteToken, _disputableVotingSettings);
        BrightIdRegister brightIdRegister = _installBrightIdRegister(dao, acl, disputableVoting, _1hiveContext, _verifiers, _brightIdSettings);
        HookedTokenManager hookedTokenManager = _installHookedTokenManagerApp(dao);

        _createDisputableVotingPermissions(acl, disputableVoting);
        _createAgentPermissions(acl, agent, ANY_ENTITY, disputableVoting);
        _createEvmScriptsRegistryPermissions(acl, disputableVoting, disputableVoting);

        _storeDeployedContractsTxOne(dao, acl, disputableVoting, fundingPoolVault, hookedTokenManager, voteToken);

        emit DisputableVotingAddress(disputableVoting);
        emit VoteToken(voteToken);
        emit VaultAddress(fundingPoolVault);
        emit AgentAddress(agent);
    }

    /**
    * @dev Add and initialise issuance and conviction voting
    * @param _issuanceSettings Array of issuance settings: [targetRatio, maxAdjustmentRatioPerSecond]
    * @param _setupAddresses Array of addresses: [stableTokenOracle, convictionVotingPauseAdmin]
    * @param _convictionSettings array of conviction settings: [decay, max_ratio, weight, min_threshold_stake_percentage]
    */
    function createDaoTxTwo(
        uint256[2] _issuanceSettings,
        ERC20 _stableToken,
        address[2] _setupAddresses,
        uint64[4] _convictionSettings
    )
        public
    {
        require(senderDeployedContracts[msg.sender].dao != address(0), ERROR_NO_CACHE);

        (Kernel dao,
        ACL acl,
        DisputableVoting disputableVoting,
        Vault fundingPoolVault,
        HookedTokenManager hookedTokenManager,
        MiniMeToken voteToken) = _getDeployedContractsTxOne();

        // Must have set the token controller to the HookedTokenManager prior to executing this transaction
        acl.createPermission(address(this), hookedTokenManager, hookedTokenManager.INIT_ROLE(), disputableVoting);
        hookedTokenManager.initialize(voteToken, TOKEN_TRANSFERABLE, TOKEN_MAX_PER_ACCOUNT);

        // TODO: Remove for prod
        // Mint some initial funds for distribution via conviction voting and for creator. Only for testing, remove for prod.
//        _createPermissionForTemplate(acl, hookedTokenManager, hookedTokenManager.MINT_ROLE());
//        hookedTokenManager.mint(msg.sender, 20000e18);
//        hookedTokenManager.mint(address(fundingPoolVault), VAULT_INITIAL_FUNDS);
//        _removePermissionFromTemplate(acl, hookedTokenManager, hookedTokenManager.MINT_ROLE());

        Issuance issuance = _installIssuance(dao, hookedTokenManager, fundingPoolVault, _issuanceSettings);
        _createIssuancePermissions(acl, issuance, disputableVoting);
        _createHookedTokenManagerPermissions(acl, disputableVoting, hookedTokenManager, issuance);

        ConvictionVoting convictionVoting = _installConvictionVoting(dao, MiniMeToken(hookedTokenManager.token()),
            _stableToken, _setupAddresses[0], fundingPoolVault, _convictionSettings);
        _createConvictionVotingPermissions(acl, convictionVoting, disputableVoting, _setupAddresses[1]);
        _createVaultPermissions(acl, fundingPoolVault, convictionVoting, disputableVoting);

        _createPermissionForTemplate(acl, hookedTokenManager, hookedTokenManager.SET_HOOK_ROLE());
        hookedTokenManager.registerHook(convictionVoting);
        _removePermissionFromTemplate(acl, hookedTokenManager, hookedTokenManager.SET_HOOK_ROLE());

        _storeDeployedContractsTxTwo(convictionVoting);
    }

    /**
    * @dev Add, initialise and activate the agreement
    */
    function createDaoTxThree(
        address _arbitrator,
        bool _setAppFeesCashier,
        string _title,
        bytes memory _content,
        address _stakingFactory,
        address _feeToken,
        uint64 _challengeDuration,
        uint256[2] _convictionVotingFees
    )
        public
    {
        require(senderDeployedContracts[msg.sender].hookedTokenManager.hasInitialized(), ERROR_NO_CACHE);

        (Kernel dao,
        ACL acl,
        DisputableVoting disputableVoting,,,) = _getDeployedContractsTxOne();
        ConvictionVoting convictionVoting = _getDeployedContractsTxTwo();

        Agreement agreement = _installAgreementApp(dao, _arbitrator, _setAppFeesCashier, _title, _content, _stakingFactory);
        _createAgreementPermissions(acl, agreement, disputableVoting, disputableVoting);
        acl.createPermission(agreement, disputableVoting, disputableVoting.SET_AGREEMENT_ROLE(), disputableVoting);
        acl.createPermission(agreement, convictionVoting, convictionVoting.SET_AGREEMENT_ROLE(), disputableVoting);

        agreement.activate(disputableVoting, _feeToken, _challengeDuration, _convictionVotingFees[0], _convictionVotingFees[1]);
        agreement.activate(convictionVoting, _feeToken, _challengeDuration, _convictionVotingFees[0], _convictionVotingFees[1]);
        _removePermissionFromTemplate(acl, agreement, agreement.MANAGE_DISPUTABLE_ROLE());

//        _validateId(_id);
        _transferRootPermissionsFromTemplateAndFinalizeDAO(dao, msg.sender);
//        _registerID(_id, dao);
        _deleteStoredContracts();

        emit AgreementAddress(agreement);
    }


    // App installation/setup functions //

    function _installHookedTokenManagerApp(Kernel _dao) internal returns (HookedTokenManager) {
        HookedTokenManager hookedTokenManager = HookedTokenManager(_installDefaultApp(_dao, HOOKED_TOKEN_MANAGER_APP_ID));
        emit HookedTokenManagerAddress(hookedTokenManager);
        return hookedTokenManager;
    }

    function _installDisputableVotingApp(Kernel _dao, MiniMeToken _token, uint64[7] memory _disputableVotingSettings)
        internal returns (DisputableVoting)
    {
        uint64 duration = _disputableVotingSettings[0];
        uint64 support = _disputableVotingSettings[1];
        uint64 acceptance = _disputableVotingSettings[2];
        uint64 delegatedVotingPeriod = _disputableVotingSettings[3];
        uint64 quietEndingPeriod = _disputableVotingSettings[4];
        uint64 quietEndingExtension = _disputableVotingSettings[5];
        uint64 executionDelay = _disputableVotingSettings[6];

        bytes memory initializeData = abi.encodeWithSelector(DisputableVoting(0).initialize.selector, _token, duration, support, acceptance, delegatedVotingPeriod, quietEndingPeriod, quietEndingExtension, executionDelay);
        return DisputableVoting(_installNonDefaultApp(_dao, DISPUTABLE_VOTING_APP_ID, initializeData));
    }

    function _installIssuance(
        Kernel _dao,
        HookedTokenManager _hookedTokenManager,
        Vault _fundingPoolVault,
        uint256[2] _issuanceSettings
    )
        internal returns (Issuance)
    {
        Issuance issuance = Issuance(_installNonDefaultApp(_dao, DYNAMIC_ISSUANCE_APP_ID));
        issuance.initialize(_hookedTokenManager, _fundingPoolVault, _issuanceSettings[0], _issuanceSettings[1]);
        return issuance;
    }

    function _installConvictionVoting(Kernel _dao, MiniMeToken _stakeAndRequestToken, ERC20 _stableToken, address _stableTokenOracle, Vault _agentOrVault, uint64[4] _convictionSettings)
        internal returns (ConvictionVoting)
    {
        ConvictionVoting convictionVoting = ConvictionVoting(_installNonDefaultApp(_dao, CONVICTION_VOTING_APP_ID));
        convictionVoting.initialize(_stakeAndRequestToken, _stakeAndRequestToken, _stableToken, _stableTokenOracle, _agentOrVault, _convictionSettings[0], _convictionSettings[1], _convictionSettings[2], _convictionSettings[3]);
        emit ConvictionVotingAddress(convictionVoting);
        return convictionVoting;
    }

    function _installBrightIdRegister(Kernel _dao, ACL _acl, DisputableVoting _disputableVoting, bytes32 _1hiveContext, address[] _verifiers, uint256[3] _brightIdSettings)
        internal returns (BrightIdRegister)
    {
        BrightIdRegister brightIdRegister = BrightIdRegister(_installNonDefaultApp(_dao, BRIGHTID_REGISTER_APP_ID));
        brightIdRegister.initialize(_1hiveContext, _verifiers, _brightIdSettings[0], _brightIdSettings[1], _brightIdSettings[2]);
        emit BrightIdRegisterAddress(brightIdRegister);

        _acl.createPermission(ANY_ENTITY, brightIdRegister, brightIdRegister.UPDATE_SETTINGS_ROLE(), _disputableVoting);
        return brightIdRegister;
    }

    function _installAgreementApp(Kernel _dao, address _arbitrator, bool _setAppFeesCashier, string _title, bytes _content, address _stakingFactory)
        internal returns (Agreement)
    {
        bytes memory initializeData = abi.encodeWithSelector(Agreement(0).initialize.selector, _arbitrator, _setAppFeesCashier, _title, _content, _stakingFactory);
        return Agreement(_installNonDefaultApp(_dao, AGREEMENT_APP_ID, initializeData));
    }

    // Permission setting functions //

    function _createDisputableVotingPermissions(ACL _acl, DisputableVoting _disputableVoting)
        internal
    {
        _acl.createPermission(ANY_ENTITY, _disputableVoting, _disputableVoting.CHALLENGE_ROLE(), _disputableVoting);
        _acl.createPermission(ANY_ENTITY, _disputableVoting, _disputableVoting.CREATE_VOTES_ROLE(), _disputableVoting);
        _acl.createPermission(_disputableVoting, _disputableVoting, _disputableVoting.CHANGE_VOTE_TIME_ROLE(), _disputableVoting);
        _acl.createPermission(_disputableVoting, _disputableVoting, _disputableVoting.CHANGE_SUPPORT_ROLE(), _disputableVoting);
        _acl.createPermission(_disputableVoting, _disputableVoting, _disputableVoting.CHANGE_QUORUM_ROLE(), _disputableVoting);
        _acl.createPermission(_disputableVoting, _disputableVoting, _disputableVoting.CHANGE_DELEGATED_VOTING_PERIOD_ROLE(), _disputableVoting);
        _acl.createPermission(_disputableVoting, _disputableVoting, _disputableVoting.CHANGE_QUIET_ENDING_ROLE(), _disputableVoting);
        _acl.createPermission(_disputableVoting, _disputableVoting, _disputableVoting.CHANGE_EXECUTION_DELAY_ROLE(), _disputableVoting);
    }

    function _createIssuancePermissions(ACL _acl, Issuance _issuance, DisputableVoting _disputableVoting) internal {
        _acl.createPermission(_disputableVoting, _issuance, _issuance.UPDATE_SETTINGS_ROLE(), _disputableVoting);
    }

    function _createConvictionVotingPermissions(ACL _acl, ConvictionVoting _convictionVoting, DisputableVoting _disputableVoting, address _pauseAdmin)
        internal
    {
        _acl.createPermission(ANY_ENTITY, _convictionVoting, _convictionVoting.CHALLENGE_ROLE(), _disputableVoting);
        _acl.createPermission(ANY_ENTITY, _convictionVoting, _convictionVoting.CREATE_PROPOSALS_ROLE(), _disputableVoting);
        _acl.createPermission(_pauseAdmin, _convictionVoting, _convictionVoting.PAUSE_CONTRACT_ROLE(), _disputableVoting);
        _acl.createPermission(_disputableVoting, _convictionVoting, _convictionVoting.CANCEL_PROPOSALS_ROLE(), _disputableVoting);
        _acl.createPermission(_disputableVoting, _convictionVoting, _convictionVoting.UPDATE_SETTINGS_ROLE(), _disputableVoting);
    }

    function _createHookedTokenManagerPermissions(ACL acl, DisputableVoting disputableVoting, HookedTokenManager hookedTokenManager, Issuance issuance) internal {
        // TODO: Remove this permission for live deployment !!! ARGH !!!
        acl.createPermission(ANY_ENTITY, hookedTokenManager, hookedTokenManager.CHANGE_CONTROLLER_ROLE(), disputableVoting);
        acl.createPermission(issuance, hookedTokenManager, hookedTokenManager.MINT_ROLE(), disputableVoting);
        acl.createPermission(issuance, hookedTokenManager, hookedTokenManager.BURN_ROLE(), disputableVoting);
        // acl.createPermission(issuance, hookedTokenManager, hookedTokenManager.ISSUE_ROLE(), disputableVoting);
        // acl.createPermission(issuance, hookedTokenManager, hookedTokenManager.ASSIGN_ROLE(), disputableVoting);
        // acl.createPermission(issuance, hookedTokenManager, hookedTokenManager.REVOKE_VESTINGS_ROLE(), disputableVoting);
    }

    function _createAgreementPermissions(ACL _acl, Agreement _agreement, address _grantee, address _manager) internal {
        _acl.createPermission(_grantee, _agreement, _agreement.CHANGE_AGREEMENT_ROLE(), _manager);
        _acl.createPermission(address(this), _agreement, _agreement.MANAGE_DISPUTABLE_ROLE(), address(this));
    }

    // Temporary Storage functions //

    function _storeDeployedContractsTxOne(Kernel _dao, ACL _acl, DisputableVoting _disputableVoting, Vault _agentOrVault, HookedTokenManager _hookedTokenManager, MiniMeToken _voteToken )
        internal
    {
        DeployedContracts storage deployedContracts = senderDeployedContracts[msg.sender];
        deployedContracts.dao = _dao;
        deployedContracts.acl = _acl;
        deployedContracts.disputableVoting = _disputableVoting;
        deployedContracts.fundingPoolVault = _agentOrVault;
        deployedContracts.hookedTokenManager = _hookedTokenManager;
        deployedContracts.voteToken = _voteToken;
    }

    function _getDeployedContractsTxOne() internal returns (Kernel, ACL, DisputableVoting, Vault, HookedTokenManager, MiniMeToken voteToken) {
        DeployedContracts storage deployedContracts = senderDeployedContracts[msg.sender];
        return (
            deployedContracts.dao,
            deployedContracts.acl,
            deployedContracts.disputableVoting,
            deployedContracts.fundingPoolVault,
            deployedContracts.hookedTokenManager,
            deployedContracts.voteToken
        );
    }

    function _storeDeployedContractsTxTwo(ConvictionVoting _convictionVoting) internal {
        DeployedContracts storage deployedContracts = senderDeployedContracts[msg.sender];
        deployedContracts.convictionVoting = _convictionVoting;
    }

    function _getDeployedContractsTxTwo() internal returns (ConvictionVoting) {
        DeployedContracts storage deployedContracts = senderDeployedContracts[msg.sender];
        return deployedContracts.convictionVoting;
    }

    function _deleteStoredContracts() internal {
        delete senderDeployedContracts[msg.sender];
    }

    // Oracle permissions with params functions //

    function _setOracle(ACL _acl, address _who, address _where, bytes32 _what, address _oracle) private {
        uint256[] memory params = new uint256[](1);
        params[0] = _paramsTo256(ORACLE_PARAM_ID, uint8(Op.EQ), uint240(_oracle));

        _acl.grantPermissionP(_who, _where, _what, params);
    }

    function _paramsTo256(uint8 _id,uint8 _op, uint240 _value) private returns (uint256) {
        return (uint256(_id) << 248) + (uint256(_op) << 240) + _value;
    }
}
