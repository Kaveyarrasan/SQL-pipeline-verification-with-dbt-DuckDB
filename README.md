# SQL Pipeline Verification with dbt + DuckDB

A local, reproducible testing harness for validating analytical SQL, built while debugging a real Python/dbt environment conflict along the way.

## Business Framing

Analytical SQL correctness is usually verified by eyeballing results or trusting an interview platform's hidden test cases. Neither approach scales, and neither leaves an audit trail. This project treats a single analytical SQL question — *"find the customer(s) with the highest daily total order cost in a date range"* — as a **testable data pipeline**, using dbt as the transformation/testing layer and DuckDB as a zero-infrastructure local warehouse.

The pattern generalizes: any SQL logic (a business rule, a migration script, a candidate solution) can be seeded, modeled, and validated locally before it ever touches a real warehouse.

## Architecture

```
seeds/customers.csv, seeds/orders.csv   (raw source data)
        |
        v
   dbt seed                              -> loads CSVs as tables in DuckDB
        |
        v
   models/highest_daily_orders.sql       -> CTE pipeline:
        |                                    1. parse text dates -> DATE type
        |                                    2. sum order costs per (customer, day)
        |                                    3. rank days by total, filter to max
        |                                    4. join back to customer names
        v
   dev.duckdb (local file, no server)
```

**Why dbt + DuckDB instead of a notebook or raw SQL script:**
- dbt gives version-controlled, testable models instead of throwaway scratch queries — the same discipline used in production warehouses.
- DuckDB requires no server, no credentials, no cloud account — it runs embedded in-process, making it ideal for local verification before deploying logic to Snowflake/BigQuery/Redshift.
- The `{{ ref() }}` pattern and seed-based test fixtures are portable: this exact project structure could be repointed at a real warehouse by swapping one YAML file.

## Architecture Decisions

| Decision | Reasoning |
|---|---|
| **DuckDB over Postgres/Snowflake for local testing** | Zero infrastructure — no Docker, no login, no billing. Fast to iterate on and easy for a reviewer to clone and run in minutes. |
| **Seeds instead of a live source connection** | Deterministic and reproducible — anyone running `dbt seed && dbt run` gets identical results. |
| **Explicit `strptime()` date parsing in the model, not relying on seed auto-typing** | dbt's seed loader infers column types conservatively and left `order_date` as `VARCHAR`. Trusting that inference would have shipped a pipeline that **ran without error but returned wrong (empty) results** — a classic, dangerous failure mode. |
| **Independent verification query outside the model** | Never trust a pipeline's own output as its only witness — cross-checked the model's result against a separate aggregation query before accepting it as correct. |

## The Debugging Journey

Three separate, realistic failures surfaced while building this.

### Issue 1 — Environment: Python 3.14 / mashumaro incompatibility
**Symptom:** `dbt --version` crashed with `mashumaro.exceptions.UnserializableField` before dbt ran a single command.
**Root cause:** dbt-core pins `mashumaro<3.15`, which is incompatible with Python 3.14.
**Fix:** Rebuilt the virtual environment against Python 3.11 (later verified again against 3.12), the versions dbt-core is actually tested against.
**Lesson:** When a new tool fails on install, check version compatibility matrices before assuming the tool is broken.

### Issue 2 — Schema drift: seed CSVs didn't match the real dataset
**Symptom:** `dbt seed` failed with a DuckDB CSV-sniffing error — "columns are set as 2, sniffer found 6."
**Root cause:** Placeholder seed files used to unblock environment setup had a narrower schema than the real dataset added afterward; stale `target/` and `dev.duckdb` state compounded the mismatch.
**Fix:** Cleared `dev.duckdb` and `target/`, then reseeded with `--full-refresh`.
**Lesson:** Stateful local databases silently carry forward schema from earlier iterations — clear target state as a standard first step when swapping in new source data, not a last resort.

### Issue 3 — Silent logic failure: string dates vs. real dates
**Symptom:** The model ran with **no errors** and built successfully — but querying it returned `[]`.
**Root cause:** `order_date` loaded as `VARCHAR` (e.g. `'3/4/2019'`), so a `WHERE order_date BETWEEN '2019-02-01' AND '2019-05-01'` filter silently ran as a **string comparison**, not a date comparison — matching almost nothing, with zero warnings.
**Fix:** Added an explicit `strptime(order_date, '%-m/%-d/%Y')::date` cast before any filtering or aggregation.
**Lesson:** A pipeline that runs without error is not a pipeline that's correct. Silent type coercion in filters is a common source of "the numbers are just wrong and nobody noticed" incidents.

## Result

```
first_name | total_cost_cust_date | order_date
-----------+-----------------------+------------
Jill       | 275                   | 2019-04-19
Mark       | 275                   | 2019-04-19
```

A genuine tie: two customers each hit a daily total of 275 on the same date, correctly surfaced by `RANK()` rather than silently dropped by `ROW_NUMBER()`.

## What I'd Add for Production

- Additional dbt tests (`accepted_range` on `order_date`, freshness checks) to catch the string-vs-date issue automatically instead of requiring a manual "why is this empty" investigation.
- A CI step running `dbt build` on every pull request.
- Data contracts on any upstream source that supplies typed date columns, rather than relying on inference at seed/ingestion time.

## Running This Project

```bash
python3 -m venv venv
source venv/bin/activate   # on Windows: venv\Scripts\activate
pip install dbt-core dbt-duckdb

dbt seed --full-refresh
dbt run
dbt test
```

Then query the result directly:

```python
import duckdb
con = duckdb.connect('dev.duckdb')
print(con.sql('select * from main.highest_daily_orders').fetchall())
```

## Tech Stack

Python, dbt-core, dbt-duckdb, DuckDB, SQL (CTEs, window functions, RANK())
