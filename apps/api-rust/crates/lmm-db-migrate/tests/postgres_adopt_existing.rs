use std::{
    fs,
    path::{Path, PathBuf},
    sync::{Mutex, MutexGuard},
};

use lmm_db_migrate::{
    postgres_adopt::{
        AdoptExistingOptions, AdoptionError, AdoptionOutcome, MaintenanceQuiescenceAttestation,
        adopt_existing,
    },
    postgres_catalog::{CatalogError, begin_catalog_inspection, fingerprint},
    release::{ReleaseId, Sha256Digest},
};
use postgres::{Client, NoTls};
use sha2::{Digest, Sha256};
use tempfile::TempDir;

static ISOLATED_DATABASE: Mutex<()> = Mutex::new(());

struct AdoptionFixture {
    _directory: TempDir,
    database_url: String,
    plan_path: PathBuf,
    plan_sha256: Sha256Digest,
    database: String,
    role: String,
    release_revision: ReleaseId,
    release_artifact_sha256: Sha256Digest,
    maintenance_quiescence: MaintenanceQuiescenceAttestation,
}

impl AdoptionFixture {
    fn options(&self) -> AdoptExistingOptions<'_> {
        AdoptExistingOptions {
            database_url: &self.database_url,
            plan: &self.plan_path,
            expected_plan_sha256: &self.plan_sha256,
            expected_database: &self.database,
            expected_role: &self.role,
            release_revision: &self.release_revision,
            release_artifact_sha256: &self.release_artifact_sha256,
            maintenance_quiescence: &self.maintenance_quiescence,
        }
    }
}

#[test]
#[ignore = "requires an isolated native PostgreSQL database and LMM_TEST_ADOPT_DATABASE_URL"]
fn adoption_should_commit_once_replay_without_writes_and_reject_partial_ledger() {
    let _database_guard = isolated_database_guard();
    let database_url = std::env::var("LMM_TEST_ADOPT_DATABASE_URL")
        .expect("explicit isolated adoption test database URL");
    let (database, role, postgres_major, catalog_sha256) = inspect_target(&database_url);
    assert_ledger_absent(&database_url);

    let directory = tempfile::tempdir().expect("temporary plan directory");
    let plan_path = directory.path().join("plan.json");
    let release_artifact_sha256 = digest(b"isolated adoption integration release");
    let release_revision: ReleaseId = "adoption-integration-1"
        .parse()
        .expect("valid release revision");
    write_plan(
        &plan_path,
        &database,
        &role,
        postgres_major,
        release_revision.as_str(),
        &release_artifact_sha256,
        &catalog_sha256,
    );
    let plan_sha256 = digest(&fs::read(&plan_path).expect("read plan bytes"));
    let maintenance_quiescence = test_maintenance_quiescence();
    let options = AdoptExistingOptions {
        database_url: &database_url,
        plan: &plan_path,
        expected_plan_sha256: &plan_sha256,
        expected_database: &database,
        expected_role: &role,
        release_revision: &release_revision,
        release_artifact_sha256: &release_artifact_sha256,
        maintenance_quiescence: &maintenance_quiescence,
    };

    let adopted = adopt_existing(&options).expect("adopt isolated database");
    assert_eq!(adopted.status, AdoptionOutcome::Adopted);
    assert_runtime_schema_report(&adopted);
    assert_eq!(ledger_rows(&database_url), 1);

    let replayed = adopt_existing(&options).expect("verify exact replay");
    assert_eq!(replayed.status, AdoptionOutcome::AlreadyApplied);
    assert_runtime_schema_report(&replayed);
    assert_eq!(ledger_rows(&database_url), 1);

    drop_control_schema(&database_url);
    let mut client = Client::connect(&database_url, NoTls).expect("connect for partial state");
    client
        .batch_execute("CREATE SCHEMA lmm_meta")
        .expect("create partial control schema");
    drop(client);
    assert!(matches!(
        adopt_existing(&options),
        Err(AdoptionError::LedgerConflict)
    ));
    drop_control_schema(&database_url);
}

#[test]
#[ignore = "requires an isolated native PostgreSQL database and LMM_TEST_ADOPT_DATABASE_URL"]
fn catalog_lock_should_acquire_immediately_when_uncontended() {
    let _database_guard = isolated_database_guard();
    let database_url = test_database_url();
    let mut client = Client::connect(&database_url, NoTls).expect("connect for lock acquisition");
    let mut transaction = client.transaction().expect("start lock transaction");

    let result = begin_catalog_inspection(&mut transaction);

    transaction.rollback().expect("release acquired lock");
    assert!(result.is_ok(), "lock acquisition failed: {result:?}");
}

#[test]
#[ignore = "requires an isolated native PostgreSQL database and LMM_TEST_ADOPT_DATABASE_URL"]
fn catalog_lock_should_time_out_when_contended() {
    let _database_guard = isolated_database_guard();
    let database_url = test_database_url();
    let mut holder = Client::connect(&database_url, NoTls).expect("connect lock holder");
    let mut holder_transaction = holder.transaction().expect("start holder transaction");
    begin_catalog_inspection(&mut holder_transaction).expect("acquire holder lock");
    let mut waiter = Client::connect(&database_url, NoTls).expect("connect lock waiter");
    let mut waiter_transaction = waiter.transaction().expect("start waiter transaction");

    let result = begin_catalog_inspection(&mut waiter_transaction);

    holder_transaction.rollback().expect("release holder lock");
    assert!(matches!(result, Err(CatalogError::LockAcquisitionTimeout)));
}

#[test]
#[ignore = "requires an isolated native PostgreSQL database and LMM_TEST_ADOPT_DATABASE_URL"]
fn catalog_lock_should_release_after_holder_rollback() {
    let _database_guard = isolated_database_guard();
    let database_url = test_database_url();
    let mut holder = Client::connect(&database_url, NoTls).expect("connect lock holder");
    let mut holder_transaction = holder.transaction().expect("start holder transaction");
    begin_catalog_inspection(&mut holder_transaction).expect("acquire holder lock");
    holder_transaction.rollback().expect("roll back holder");
    let mut waiter = Client::connect(&database_url, NoTls).expect("connect lock waiter");
    let mut waiter_transaction = waiter.transaction().expect("start waiter transaction");

    let result = begin_catalog_inspection(&mut waiter_transaction);

    waiter_transaction.rollback().expect("release waiter lock");
    assert!(result.is_ok(), "lock acquisition failed: {result:?}");
}

#[test]
#[ignore = "requires an isolated native PostgreSQL database and LMM_TEST_ADOPT_DATABASE_URL"]
fn catalog_lock_should_release_after_holder_commit() {
    let _database_guard = isolated_database_guard();
    let database_url = test_database_url();
    let mut holder = Client::connect(&database_url, NoTls).expect("connect lock holder");
    let mut holder_transaction = holder.transaction().expect("start holder transaction");
    begin_catalog_inspection(&mut holder_transaction).expect("acquire holder lock");
    holder_transaction.commit().expect("commit holder");
    let mut waiter = Client::connect(&database_url, NoTls).expect("connect lock waiter");
    let mut waiter_transaction = waiter.transaction().expect("start waiter transaction");

    let result = begin_catalog_inspection(&mut waiter_transaction);

    waiter_transaction.rollback().expect("release waiter lock");
    assert!(result.is_ok(), "lock acquisition failed: {result:?}");
}

#[test]
#[ignore = "requires an isolated native PostgreSQL database and LMM_TEST_ADOPT_DATABASE_URL"]
fn adoption_lock_timeout_should_not_create_ledger() {
    let _database_guard = isolated_database_guard();
    let database_url = test_database_url();
    drop_control_schema_if_exists(&database_url);
    let fixture = adoption_fixture(database_url);
    let mut holder = Client::connect(&fixture.database_url, NoTls).expect("connect lock holder");
    let mut holder_transaction = holder.transaction().expect("start holder transaction");
    begin_catalog_inspection(&mut holder_transaction).expect("acquire holder lock");

    let result = adopt_existing(&fixture.options());

    holder_transaction.rollback().expect("release holder lock");
    assert!(matches!(
        result,
        Err(AdoptionError::Catalog(CatalogError::LockAcquisitionTimeout))
    ));
    assert_ledger_absent(&fixture.database_url);
}

fn assert_runtime_schema_report(report: &lmm_db_migrate::postgres_adopt::AdoptionReport) {
    assert_eq!(report.configured_search_path, "public");
    assert_eq!(report.current_schema, "public");
    assert_eq!(report.effective_schemas[0], "pg_catalog");
    assert_eq!(report.effective_schemas[1], "public");
}

fn isolated_database_guard() -> MutexGuard<'static, ()> {
    ISOLATED_DATABASE
        .lock()
        .unwrap_or_else(|error| error.into_inner())
}

fn test_database_url() -> String {
    std::env::var("LMM_TEST_ADOPT_DATABASE_URL")
        .expect("explicit isolated adoption test database URL")
}

fn adoption_fixture(database_url: String) -> AdoptionFixture {
    let (database, role, postgres_major, catalog_sha256) = inspect_target(&database_url);
    let directory = tempfile::tempdir().expect("temporary plan directory");
    let plan_path = directory.path().join("plan.json");
    let release_artifact_sha256 = digest(b"isolated adoption lock timeout release");
    let release_revision: ReleaseId = "adoption-lock-timeout-1"
        .parse()
        .expect("valid release revision");
    write_plan(
        &plan_path,
        &database,
        &role,
        postgres_major,
        release_revision.as_str(),
        &release_artifact_sha256,
        &catalog_sha256,
    );
    let plan_sha256 = digest(&fs::read(&plan_path).expect("read plan bytes"));

    AdoptionFixture {
        _directory: directory,
        database_url,
        plan_path,
        plan_sha256,
        database,
        role,
        release_revision,
        release_artifact_sha256,
        maintenance_quiescence: test_maintenance_quiescence(),
    }
}

fn inspect_target(database_url: &str) -> (String, String, i32, Sha256Digest) {
    let mut client = Client::connect(database_url, NoTls).expect("connect to isolated database");
    let mut transaction = client.transaction().expect("start catalog transaction");
    begin_catalog_inspection(&mut transaction).expect("lock catalog inspection");
    transaction
        .batch_execute("SET LOCAL search_path = public")
        .expect("harden search path");
    let catalog = fingerprint(&mut transaction).expect("fingerprint public catalog");
    transaction.rollback().expect("roll back inspection");
    (
        catalog.identity.database,
        catalog.identity.role,
        catalog.identity.postgres_major,
        catalog.sha256,
    )
}

fn assert_ledger_absent(database_url: &str) {
    let mut client = Client::connect(database_url, NoTls).expect("connect for precondition");
    let exists: bool = client
        .query_one(
            "SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname='lmm_meta')",
            &[],
        )
        .expect("inspect control schema")
        .get(0);
    assert!(!exists, "isolated test database must not contain lmm_meta");
}

fn ledger_rows(database_url: &str) -> i64 {
    let mut client = Client::connect(database_url, NoTls).expect("connect to read ledger");
    client
        .query_one(
            "SELECT count(*)::bigint FROM lmm_meta.lmm_adoption_ledger",
            &[],
        )
        .expect("count adoption rows")
        .get(0)
}

fn drop_control_schema(database_url: &str) {
    let mut client = Client::connect(database_url, NoTls).expect("connect for test cleanup");
    client
        .batch_execute("DROP SCHEMA lmm_meta CASCADE")
        .expect("drop isolated test control schema");
}

fn drop_control_schema_if_exists(database_url: &str) {
    let mut client = Client::connect(database_url, NoTls).expect("connect for test cleanup");
    client
        .batch_execute("DROP SCHEMA IF EXISTS lmm_meta CASCADE")
        .expect("drop isolated test control schema when present");
}

fn test_maintenance_quiescence() -> MaintenanceQuiescenceAttestation {
    MaintenanceQuiescenceAttestation {
        format_version: 1,
        status: "verified".into(),
        verifier: "adoption-integration-verifier".into(),
        service_stopped: true,
        migration_capable_sessions: 0,
        principal_scope: "deployment_managed_only".into(),
    }
}

fn write_plan(
    path: &Path,
    database: &str,
    role: &str,
    postgres_major: i32,
    release_revision: &str,
    release_artifact_sha256: &Sha256Digest,
    catalog_sha256: &Sha256Digest,
) {
    let plan = serde_json::json!({
        "format_version": 2,
        "operation": "postgres_adopt_existing",
        "app_schema": "public",
        "control_schema": "lmm_meta",
        "expected_database": database,
        "expected_role": role,
        "expected_postgres_major": postgres_major,
        "expected_configured_search_path": "public",
        "expected_current_schema": "public",
        "expected_effective_schemas": ["pg_catalog", "public"],
        "release_revision": release_revision,
        "release_artifact_sha256": release_artifact_sha256.as_str(),
        "expected_public_catalog_sha256": catalog_sha256.as_str(),
        "maintenance_quiescence": test_maintenance_quiescence(),
        "application_ddl": [],
    });
    fs::write(
        path,
        serde_json::to_vec_pretty(&plan).expect("serialize strict plan"),
    )
    .expect("write strict plan");
}

fn digest(bytes: &[u8]) -> Sha256Digest {
    Sha256Digest::parse(&format!("{:x}", Sha256::digest(bytes)), "test").expect("valid SHA-256")
}
