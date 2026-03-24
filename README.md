# SourceMap Upload Scripts

This repository provides two scripts for uploading an existing `sourcemap.zip` through OpenAPI:

- `upload-sourcemap.sh`
- `upload_sourcemap.py`

The scripts upload an already prepared zip file only. They do not generate or package sourcemaps.

For product background, SourceMap packaging requirements, parameter source instructions, and troubleshooting details, refer to the official documentation:

- https://docs.truewatch.com/real-user-monitoring/sourcemap/script-upload-sourcemap

## Requirements

- Shell script:
  - `bash`
  - `curl`
  - `jq`
  - `split`
  - `mktemp`
  - `wc`
- Python script:
  - `python3`

## Quick Start

Shell:

```bash
sh ./upload-sourcemap.sh \
  --endpoint https://your-openapi-endpoint \
  --api-key "$DF_API_KEY" \
  --app-id app_id_from_studio \
  --version 1.0.2 \
  --env daily \
  --file ./sourcemap.zip \
  --need-cover true
```

Python:

```bash
python3 ./upload_sourcemap.py \
  --endpoint https://your-openapi-endpoint \
  --api-key "$DF_API_KEY" \
  --app-id app_id_from_studio \
  --version 1.0.2 \
  --env daily \
  --file ./sourcemap.zip \
  --need-cover true
```

Expected output:

- `Init succeeded, uploadId=...`
- `Uploading part x/y`
- `Merge succeeded via /api/v1/rum_sourcemap/part_merge`
- `Upload complete`

## Arguments

Required:

- `--endpoint`: OpenAPI base URL
- `--api-key`: `DF-API-KEY`
- `--app-id`: RUM application ID
- `--file`: path to `sourcemap.zip`

Optional:

- `--version`: application version
- `--env`: deployment environment, for example `daily`, `gray`, or `prod`
- `--need-cover`: `true` or `false`, default is `false`
- `--chunk-size-mb`: multipart chunk size in MB, default is `10`, max is `10`
- `--merge-path`: custom merge endpoint path
- `--cancel-path`: custom cancel endpoint path

## Environment Variables

```bash
export DF_OPENAPI_ENDPOINT="https://your-openapi-endpoint"
export DF_API_KEY="your-api-key"
export DF_APP_ID="app_id_from_studio"
export DF_VERSION="1.0.2"
export DF_ENV="daily"
export DF_SOURCEMAP_FILE="./sourcemap.zip"
export DF_NEED_COVER="true"
```

Then run:

```bash
sh ./upload-sourcemap.sh
```

Or:

```bash
python3 ./upload_sourcemap.py
```
