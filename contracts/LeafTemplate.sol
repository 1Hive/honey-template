pragma solidity 0.4.24;

import "@aragon/templates-shared/contracts/BaseTemplate.sol";
import "@1hive/apps-dandelion-voting/contracts/DandelionVoting.sol";
import {IHookedTokenWrapper as HookedTokenWrapper} from "./external/IHookedTokenWrapper.sol";
import {ITollgate as Tollgate} from "./external/ITollgate.sol";
import {IConvictionVoting as ConvictionVoting} from "./external/IConvictionVoting.sol";


contract LeafTemplate is BaseTemplate {

    string constant private ERROR_MISSING_MEMBERS = "MISSING_MEMBERS";
    string constant private ERROR_BAD_VOTE_SETTINGS = "BAD_SETTINGS";
    string constant private ERROR_NO_CACHE = "NO_CACHE";
    string constant private ERROR_NO_TOLLGATE_TOKEN = "NO_TOLLGATE_TOKEN";

    //
    // bytes32 private constant DANDELION_VOTING_APP_ID = keccak256(abi.encodePacked(apmNamehash("open"), keccak256("gardens-dandelion-voting")));
    // bytes32 private constant CONVICTION_VOTING_APP_ID = keccak256(abi.encodePacked(apmNamehash("open"), keccak256("gardens-dependency")));
    // bytes32 private constant HOOKED_TOKEN_WRAPPER_APP_ID = keccak256(abi.encodePacked(apmNamehash("open"), keccak256("token-wrapper")));
    // bytes32 private constant TOLLGATE_APP_ID = keccak256(abi.encodePacked(apmNamehash("open"), keccak256("tollgate")));

    // xdai

    bytes32 private constant DANDELION_VOTING_APP_ID = keccak256(abi.encodePacked(apmNamehash("1hive"), keccak256("dandelion-voting")));
    bytes32 private constant CONVICTION_VOTING_APP_ID = apmNamehash("conviction-beta");
    bytes32 private constant HOOKED_TOKEN_WRAPPER_APP_ID = keccak256(abi.encodePacked(apmNamehash("open"), keccak256("hooked-token-wrapper")));
    bytes32 private constant TOLLGATE_APP_ID = keccak256(abi.encodePacked(apmNamehash("1hive"), keccak256("tollgate")));


    bool private constant TOKEN_TRANSFERABLE = true;
    uint8 private constant TOKEN_DECIMALS = uint8(18);
    uint256 private constant TOKEN_MAX_PER_ACCOUNT = uint256(-1);
    address private constant ANY_ENTITY = address(-1);
    uint8 private constant ORACLE_PARAM_ID = 203;
    enum Op { NONE, EQ, NEQ, GT, LT, GTE, LTE, RET, NOT, AND, OR, XOR, IF_ELSE }

    struct DeployedContracts {
        Kernel dao;
        ACL acl;
        DandelionVoting dandelionVoting;
        Vault fundingPoolVault;
        HookedTokenWrapper hookedTokenWrapper;
    }

    mapping(address => DeployedContracts) internal senderDeployedContracts;

    constructor(DAOFactory _daoFactory, ENS _ens, MiniMeTokenFactory _miniMeFactory, IFIFSResolvingRegistrar _aragonID)
        BaseTemplate(_daoFactory, _ens, _miniMeFactory, _aragonID)
        public
    {
        _ensureAragonIdIsValid(_aragonID);
        _ensureMiniMeFactoryIsValid(_miniMeFactory);
    }

    // New DAO functions //

    /**
    * @dev Create the DAO and initialise the basic apps necessary for gardens
    * @param _token Token to be wrapped
    * @param _wrappedTokenName The name for the token used by share holders in the organization
    * @param _wrappedTokenSymbol The symbol for the token used by share holders in the organization
    * @param _votingSettings Array of [supportRequired, minAcceptanceQuorum, voteDuration, voteBufferBlocks, voteExecutionDelayBlocks] to set up the voting app of the organization

    */
    function createDaoTxOne(
        ERC20 _token,
        string _wrappedTokenName,
        string _wrappedTokenSymbol,
        uint64[5] _votingSettings
    )
        public
    {
        require(_votingSettings.length == 5, ERROR_BAD_VOTE_SETTINGS);

        (Kernel dao, ACL acl) = _createDAO();
        HookedTokenWrapper hookedTokenWrapper = _installHookedTokenWrapperApp(dao, _token, _wrappedTokenName, _wrappedTokenSymbol);
        Vault fundingPoolVault = _installVaultApp(dao);
        DandelionVoting dandelionVoting = _installDandelionVotingApp(dao, hookedTokenWrapper, _votingSettings);

        _createHookedTokenWrapperPermissions(acl, dandelionVoting, hookedTokenWrapper);
        _createEvmScriptsRegistryPermissions(acl, dandelionVoting, dandelionVoting);
        _createCustomVotingPermissions(acl, dandelionVoting);

        _storeDeployedContractsTxOne(dao, acl, dandelionVoting, fundingPoolVault, hookedTokenWrapper);
    }

    /**
    * @dev Add and initialise tollgate and conviction voting
    * @param _requestToken Token of the funding pool
    * @param _convictionSettings array of conviction settings: decay, max_ratio, and weight
    */
    function createDaoTxTwo(
        address _requestToken,
        uint64[4] _convictionSettings
    )
        public
    {
        require(senderDeployedContracts[msg.sender].dao != address(0), ERROR_NO_CACHE);

        (Kernel dao,
        ACL acl,
        DandelionVoting dandelionVoting,
        Vault fundingPoolVault,
        HookedTokenWrapper hookedTokenWrapper) = _getDeployedContractsTxOne();

        ERC20 feeToken = ERC20(address(hookedTokenWrapper));

        Tollgate tollgate = _installTollgate(senderDeployedContracts[msg.sender].dao, feeToken, 0, address(fundingPoolVault));
        _createTollgatePermissions(acl, tollgate, dandelionVoting);

        ConvictionVoting convictionVoting = _installConvictionVoting(senderDeployedContracts[msg.sender].dao, hookedTokenWrapper, fundingPoolVault, _requestToken, _convictionSettings);
        _createVaultPermissions(acl, fundingPoolVault, convictionVoting, dandelionVoting);
        _createConvictionVotingPermissions(acl, convictionVoting, dandelionVoting);

        _createPermissionForTemplate(acl, hookedTokenWrapper, hookedTokenWrapper.SET_HOOK_ROLE());
        hookedTokenWrapper.registerHook(convictionVoting);
        hookedTokenWrapper.registerHook(dandelionVoting);
        _removePermissionFromTemplate(acl, hookedTokenWrapper, hookedTokenWrapper.SET_HOOK_ROLE());

        // _validateId(_id);
        _transferRootPermissionsFromTemplateAndFinalizeDAO(dao, dandelionVoting);
        // _registerID(_id, dao);
        _deleteStoredContracts();
    }


    // App installation/setup functions //

    function _installHookedTokenWrapperApp(
        Kernel _dao,
        ERC20 _token,
        string _wrappedTokenName,
        string _wrappedTokenSymbol
    )
        internal returns (HookedTokenWrapper)
    {
        HookedTokenWrapper hookedTokenWrapper = HookedTokenWrapper(_installDefaultApp(_dao, HOOKED_TOKEN_WRAPPER_APP_ID));
        hookedTokenWrapper.initialize(_token, _wrappedTokenName, _wrappedTokenSymbol);
        return hookedTokenWrapper;
    }

    function _installDandelionVotingApp(Kernel _dao, HookedTokenWrapper _hookedTokenWrapper, uint64[5] _votingSettings)
        internal returns (DandelionVoting)
    {
        DandelionVoting dandelionVoting = DandelionVoting(_installNonDefaultApp(_dao, DANDELION_VOTING_APP_ID));
        dandelionVoting.initialize(MiniMeToken(address(_hookedTokenWrapper)), _votingSettings[0], _votingSettings[1], _votingSettings[2],
            _votingSettings[3], _votingSettings[4]);
        return dandelionVoting;
    }

    function _installTollgate(Kernel _dao, ERC20 _tollgateFeeToken, uint256 _tollgateFeeAmount, address _tollgateFeeDestination)
        internal returns (Tollgate)
    {
        Tollgate tollgate = Tollgate(_installNonDefaultApp(_dao, TOLLGATE_APP_ID));
        tollgate.initialize(_tollgateFeeToken, _tollgateFeeAmount, _tollgateFeeDestination);
        return tollgate;
    }

    function _installConvictionVoting(Kernel _dao, HookedTokenWrapper _stakeToken, Vault _agentOrVault, address _requestToken, uint64[4] _convictionSettings)
        internal returns (ConvictionVoting)
    {
        ConvictionVoting convictionVoting = ConvictionVoting(_installNonDefaultApp(_dao, CONVICTION_VOTING_APP_ID));
        convictionVoting.initialize(MiniMeToken(address(_stakeToken)), _agentOrVault, _requestToken, _convictionSettings[0], _convictionSettings[1], _convictionSettings[2], _convictionSettings[3]);
        return convictionVoting;
    }

    // Permission setting functions //

    function _createCustomVotingPermissions(ACL _acl, DandelionVoting _dandelionVoting)
        internal
    {
        _acl.createPermission(_dandelionVoting, _dandelionVoting, _dandelionVoting.MODIFY_QUORUM_ROLE(), _dandelionVoting);
        _acl.createPermission(_dandelionVoting, _dandelionVoting, _dandelionVoting.MODIFY_SUPPORT_ROLE(), _dandelionVoting);
        _acl.createPermission(_dandelionVoting, _dandelionVoting, _dandelionVoting.MODIFY_BUFFER_BLOCKS_ROLE(), _dandelionVoting);
        _acl.createPermission(_dandelionVoting, _dandelionVoting, _dandelionVoting.MODIFY_EXECUTION_DELAY_ROLE(), _dandelionVoting);
    }

    function _createTollgatePermissions(ACL _acl, Tollgate _tollgate, DandelionVoting _dandelionVoting) internal {
        _acl.createPermission(_dandelionVoting, _tollgate, _tollgate.CHANGE_AMOUNT_ROLE(), _dandelionVoting);
        _acl.createPermission(_dandelionVoting, _tollgate, _tollgate.CHANGE_DESTINATION_ROLE(), _dandelionVoting);
        _acl.createPermission(_tollgate, _dandelionVoting, _dandelionVoting.CREATE_VOTES_ROLE(), _dandelionVoting);
    }

    function _createConvictionVotingPermissions(ACL _acl, ConvictionVoting _convictionVoting, DandelionVoting _dandelionVoting)
        internal
    {
        _acl.createPermission(ANY_ENTITY, _convictionVoting, _convictionVoting.UPDATE_SETTINGS_ROLE(), _dandelionVoting);
        _acl.createPermission(ANY_ENTITY, _convictionVoting, _convictionVoting.CREATE_PROPOSALS_ROLE(), _dandelionVoting);
        _acl.createPermission(ANY_ENTITY, _convictionVoting, _convictionVoting.CANCEL_PROPOSAL_ROLE(), _dandelionVoting);
    }

    function _createHookedTokenWrapperPermissions(ACL acl, DandelionVoting dandelionVoting, HookedTokenWrapper hookedTokenWrapper) internal {
        acl.createPermission(address(-1), hookedTokenWrapper, bytes32(-1), dandelionVoting);
    }

    // Temporary Storage functions //

    function _storeDeployedContractsTxOne(Kernel _dao, ACL _acl, DandelionVoting _dandelionVoting, Vault _agentOrVault, HookedTokenWrapper _hookedTokenWrapper)
        internal
    {
        DeployedContracts storage deployedContracts = senderDeployedContracts[msg.sender];
        deployedContracts.dao = _dao;
        deployedContracts.acl = _acl;
        deployedContracts.dandelionVoting = _dandelionVoting;
        deployedContracts.fundingPoolVault = _agentOrVault;
        deployedContracts.hookedTokenWrapper = _hookedTokenWrapper;
    }

    function _getDeployedContractsTxOne() internal view returns (Kernel, ACL, DandelionVoting, Vault, HookedTokenWrapper) {
        DeployedContracts storage deployedContracts = senderDeployedContracts[msg.sender];
        return (
            deployedContracts.dao,
            deployedContracts.acl,
            deployedContracts.dandelionVoting,
            deployedContracts.fundingPoolVault,
            deployedContracts.hookedTokenWrapper
        );
    }

    function _deleteStoredContracts() internal {
        delete senderDeployedContracts[msg.sender];
    }
}