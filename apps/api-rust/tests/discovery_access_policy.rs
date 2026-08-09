use lmm_api_rs::models::{
    discovery_access_granted, discovery_access_granted_with_local_acceptance,
};

#[test]
fn discovery_access_is_fail_closed_and_role_aware() {
    let cases = [
        ("anonymous", 0, "", 1, 0, Some(false), false),
        ("invalid principal", 7, "alice", 1, 2, Some(true), false),
        ("disabled developer", 7, "alice", 2, 1, Some(true), false),
        ("guest role", 7, "alice", 1, 0, Some(true), false),
        (
            "unactivated developer",
            7,
            "alice",
            1,
            1,
            Some(false),
            false,
        ),
        ("active developer", 7, "alice", 1, 1, Some(true), true),
        ("administrator", 7, "admin", 1, 10, Some(false), true),
        ("custom administrator role", 7, "admin", 1, 20, None, true),
        (
            "invalid ordinary override",
            7,
            "alice",
            1,
            1,
            Some(false),
            false,
        ),
        // The baseline top_ups table has no settled/credited-quota facts. A
        // paid row without an explicit trust override must remain hidden.
        (
            "baseline paid row without trust override",
            7,
            "alice",
            1,
            1,
            None,
            false,
        ),
    ];

    for (name, user_id, username, status, role, trust_granted, expected) in cases {
        assert_eq!(
            discovery_access_granted(user_id, username, status, role, trust_granted),
            expected,
            "{name}"
        );
    }
}

#[test]
fn local_acceptance_is_opt_in_and_cannot_override_an_explicit_denial() {
    assert!(!discovery_access_granted_with_local_acceptance(
        7, "alice", 1, 1, None, false
    ));
    assert!(discovery_access_granted_with_local_acceptance(
        7, "alice", 1, 1, None, true
    ));
    assert!(!discovery_access_granted_with_local_acceptance(
        7,
        "alice",
        1,
        1,
        Some(false),
        true
    ));
}
