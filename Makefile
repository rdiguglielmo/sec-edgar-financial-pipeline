# Pipeline entry points. Each target maps to one stage of the architecture.
# Scripts are added stage by stage; a target pointing at a script that does not
# exist yet will fail until that stage is built.
#
# These targets are a convenience wrapper. The README documents the equivalent
# plain commands, which are the supported path on Windows, where make is usually
# not installed.

ifeq ($(OS),Windows_NT)
	BIN := .venv/Scripts
else
	BIN := .venv/bin
endif

PYTHON := $(BIN)/python
DBT := $(BIN)/dbt

.PHONY: extract load profile incremental dbt test dq export all

# Download the quarterly ZIP archives from the SEC into data/raw/
extract:
	$(PYTHON) src/extract.py

# Load the TSV files from data/raw/ into the DuckDB raw_ schema
load:
	$(PYTHON) src/load_raw.py

# Print the evidence behind docs/data_quality.md. Read only; runs before
# modelling because several findings change the shape of the model.
profile:
	$(PYTHON) src/profile_raw.py

# Ask the SEC submissions API what the scope companies have filed since the bulk
# load, land the index and move the per company watermark. Runs before dbt,
# because stg_filing_index reads the table it writes.
incremental:
	$(PYTHON) src/incremental.py

# Build the staging models and the star schema. Run from the repository root,
# which is where the DuckDB path in dbt/profiles.yml resolves.
#
# Deliberately not "dbt build". That command interleaves models and tests and
# skips anything downstream of a failing test, which is the right default and
# the wrong one here: ten of these tests are expected to fail on documented
# properties of the source, so build never reaches the marts. Separating the
# two keeps every test at error severity instead of softening the ten to let
# the build through.
dbt:
	$(DBT) seed --project-dir dbt --profiles-dir dbt
	$(DBT) run --project-dir dbt --profiles-dir dbt

# Run the data quality tests. Exits non zero on purpose: ten of the 156 are
# expected to fail, each on a property of the source documented next to it in
# dbt/models/staging/schema.yml and dbt/models/marts/schema.yml. The run does
# not fail, the run reports.
test:
	$(DBT) test --project-dir dbt --profiles-dir dbt

# Append the result of the last dbt test run to etl.dq_check_results, read out
# of dbt's own run artefact. Run after test, never after run: every dbt
# invocation overwrites run_results.json.
dq:
	$(PYTHON) src/load_dq_results.py

# Export the marts and the quality history to Parquet for Power BI
export:
	$(PYTHON) src/export_marts.py

# The whole pipeline. test is invoked with a leading dash because it exits non
# zero by design, and stopping there would skip recording the very results that
# make it worth running.
all: extract load incremental dbt
	-$(DBT) test --project-dir dbt --profiles-dir dbt
	$(PYTHON) src/load_dq_results.py
	$(PYTHON) src/export_marts.py
