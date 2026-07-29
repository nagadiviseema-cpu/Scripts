# ResourceGovernor Backup scripts

Author: Naga Diviseema

This folder contains scripts to configure SQL Server Resource Governor for capping SQL Agent backup jobs and routing their sessions to a constrained resource pool/workload group.

Files
- sql/ResourceGovernor_Backup.sql - Main setup script. It:
  - Creates dbo.RG_BackgroundJobs (if not present) and MERGEs matching jobs into it.
  - Creates a resource pool (Pool_Backup) and workload group (Group_Backup).
  - Sets MAX_DOP and REQUEST_MAX_MEMORY_GRANT_PERCENT for the workload group.
  - Creates/updates dbo.classifier_BackgroundJobs() and attaches it as the Resource Governor classifier.
  - Provides a validation query to inspect sessions and their assigned workload group/pool.

- sql/ResourceGovernor_Uninstall.sql - Cleanup/uninstall script. It:
  - Detaches the classifier function from Resource Governor.
  - Drops the classifier function, workload group, resource pool, and the helper table.

Usage and notes
- Permission: All changes require sysadmin permissions (ALTER RESOURCE GOVERNOR, DROP/CREATE RESOURCE POOLS, etc.).
- Review & Test: Test in a non-production environment first.
- Job name pattern: Edit the @JobNamePattern variable at the top of ResourceGovernor_Backup.sql to match your job naming convention. Example patterns:
  - '%BACKUP%'
  - '%Nightly DB Backup%'

Idempotency
- The population of dbo.RG_BackgroundJobs uses MERGE so the script can be run multiple times without creating duplicate rows. If you prefer automatic removal of jobs that no longer exist, uncomment the "WHEN NOT MATCHED BY SOURCE THEN DELETE" section in ResourceGovernor_Backup.sql.

Rollback
- Use sql/ResourceGovernor_Uninstall.sql to undo the changes. Ensure no active sessions are in 'Group_Backup' before dropping the workload group.

Support
- If you want me to adjust the job-name matching pattern or add a small PowerShell script to run these scripts against multiple instances, tell me what naming convention or instances to target and I can add it.
