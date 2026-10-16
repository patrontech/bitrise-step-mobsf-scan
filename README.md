# bitrise-step-mobsf-scan

A Bitrise step that scans an IPA or APK with [MobSF](https://github.com/MobSF/Mobile-Security-Framework-MobSF), running in a local Docker container. It produces a PDF report, the full JSON report, and MobSF's scorecard.

It was written for the NFL's monthly security reports (KIBO-11985 for iOS, KIBO-11984 for Android).

## Usage

```yaml
- git::https://github.com/patrontech/bitrise-step-mobsf-scan.git@<tag>:
    inputs:
      - target_path: $BITRISE_DEPLOY_DIR/app-release.apk
      - report_prefix: NFL
- deploy-to-bitrise-io@2:
    inputs:
      - deploy_path: $MOBSF_OUTPUT_DIR
      - is_enable_public_page: "false"
      - notify_user_groups: none
```

**It needs a Linux stack.** Bitrise's macOS machines can't run Docker. To scan an IPA:

1. build it in a macOS workflow;
2. share it with `deploy-to-bitrise-io`'s `pipeline_intermediate_files`;
3. scan it in a Linux workflow of the same Pipeline, after `pull-intermediate-files`.

## Inputs

| Input | Default | Notes |
|---|---|---|
| `target_path` | (required) | The `.ipa`, `.apk`, or `.aab` to scan. |
| `platform` | from the file extension | `iOS` or `Android`. Only used in file names. |
| `report_prefix` | `MobSF` | The first part of each file name. |
| `mobsf_image` | `opensecurity/mobile-security-framework-mobsf:v4.5.3` | Keep it pinned. Scores and report layout change between MobSF versions. |
| `output_dir` | a fresh temporary directory | Must be empty or absent. |
| `startup_timeout` | `600` | Seconds to wait for MobSF to start. |
| `scan_timeout` | `3600` | Seconds the scan request may take. |

## Outputs

`MOBSF_OUTPUT_DIR`, `MOBSF_PDF_PATH`, `MOBSF_JSON_PATH`, `MOBSF_SCORECARD_PATH`, `MOBSF_APP_NAME`, `MOBSF_APP_VERSION`, `MOBSF_APP_BUILD`, `MOBSF_SECURITY_SCORE`, and `MOBSF_VERSION`.

The files are named `<prefix>-<platform>-MobSF-<YYYY-MM>-v<version>-b<build>`, with `.pdf`, `.json`, and `-scorecard.json` endings.

## Behavior

- **Findings never fail the step.** The report is the deliverable, and people triage what's in it.
- **The step fails only when it can't produce a valid report.** The PDF must start with `%PDF-` and be bigger than a trivial size.
- **A failed run keeps MobSF's container log** in the output directory.
- **The API key is generated fresh each run**, and the container is removed afterwards, so no secrets are needed.

## Testing

`bitrise run test` scans MobSF's own sample APK and IPA (from `MobSF/test_files`, pinned to a commit). It needs Docker. GitHub Actions runs it on every push to `main`.
