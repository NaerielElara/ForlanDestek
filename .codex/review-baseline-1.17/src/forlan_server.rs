pub fn install_defaults() {
    use base::config::keys;
    use hbb_common::config;

    let (Some(id_server), Some(relay_server), Some(public_key)) = (
        option_env!("FORLAN_ID_SERVER"),
        option_env!("FORLAN_RELAY_SERVER"),
        option_env!("FORLAN_SERVER_PUBLIC_KEY"),
    ) else {
        return;
    };

    let mut defaults = config::DEFAULT_SETTINGS.write().unwrap();
    defaults.insert(
        keys::OPTION_CUSTOM_RENDEZVOUS_SERVER.to_owned(),
        id_server.to_owned(),
    );
    defaults.insert(
        keys::OPTION_RELAY_SERVER.to_owned(),
        relay_server.to_owned(),
    );
    defaults.insert(keys::OPTION_KEY.to_owned(), public_key.to_owned());
    if config::APP_NAME.read().unwrap().as_str() == "ForlanDestek" {
        defaults.insert(
            keys::OPTION_TEMPORARY_PASSWORD_LENGTH.to_owned(),
            "6".to_owned(),
        );
        defaults.insert(
            hbb_common::config::keys::OPTION_ALLOW_NUMERNIC_ONE_TIME_PASSWORD.to_owned(),
            "Y".to_owned(),
        );
        drop(defaults);
        hbb_common::config::Config::set_option(
            keys::OPTION_TEMPORARY_PASSWORD_LENGTH.to_owned(),
            "6".to_owned(),
        );
        hbb_common::config::Config::set_option(
            hbb_common::config::keys::OPTION_ALLOW_NUMERNIC_ONE_TIME_PASSWORD.to_owned(),
            "Y".to_owned(),
        );
    }
}
