use lmm_db_migrate::release::{
    CompatibilityRange, ComponentHash, MANDATORY_COMPONENT_NAMES, ReleaseBinding,
    ReleaseBindingError, Sha256Digest, Version,
};

#[test]
fn release_binding_should_require_every_mandatory_component() {
    let result = ReleaseBinding::new(
        version(1),
        digest('a'),
        range(1, 2),
        range(1, 1),
        "release-1".parse().expect("valid release identifier"),
        digest('b'),
        [],
    );

    assert_eq!(
        result.unwrap_err(),
        ReleaseBindingError::MissingComponent {
            component: "api-server-binary"
        }
    );
}

#[test]
fn release_binding_should_reject_missing_and_unknown_component_names() {
    let mut missing = mandatory_components();
    missing.pop();
    assert!(matches!(
        binding(missing).unwrap_err(),
        ReleaseBindingError::MissingComponent { .. }
    ));

    let mut unknown = mandatory_components();
    unknown.push(
        format!("unexpected={}", "f".repeat(64))
            .parse()
            .expect("valid component syntax"),
    );
    assert_eq!(
        binding(unknown).unwrap_err(),
        ReleaseBindingError::UnknownComponent
    );
}

#[test]
fn compatibility_ranges_and_hashes_should_fail_closed() {
    assert_eq!(
        CompatibilityRange::new(version(2), version(1), "reader").unwrap_err(),
        ReleaseBindingError::InvertedRange { field: "reader" }
    );
    assert_eq!(
        Sha256Digest::parse(&"A".repeat(64), "release").unwrap_err(),
        ReleaseBindingError::InvalidSha256 { field: "release" }
    );
    assert!(Version::new(0, "contract_id").is_err());
}

fn version(value: u64) -> Version {
    Version::new(value, "test").expect("test version is valid")
}

fn range(minimum: u64, maximum: u64) -> CompatibilityRange {
    CompatibilityRange::new(version(minimum), version(maximum), "test")
        .expect("test range is valid")
}

fn digest(character: char) -> Sha256Digest {
    Sha256Digest::parse(&character.to_string().repeat(64), "test").expect("test digest is valid")
}

fn mandatory_components() -> Vec<ComponentHash> {
    MANDATORY_COMPONENT_NAMES
        .iter()
        .map(|name| {
            format!("{name}={}", "f".repeat(64))
                .parse()
                .expect("mandatory component is valid")
        })
        .collect()
}

fn binding(components: Vec<ComponentHash>) -> Result<ReleaseBinding, ReleaseBindingError> {
    ReleaseBinding::new(
        version(1),
        digest('a'),
        range(1, 2),
        range(1, 1),
        "release-1".parse().expect("valid release identifier"),
        digest('b'),
        components,
    )
}
