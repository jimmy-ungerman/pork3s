# kritika vchord 1.1.1 ➔ 1.3.0 upgrade

Applies to the `kritika-postgres` CNPG cluster in `kritika-system`
(`ghcr.io/tensorchord/vchord-scratch:pg18-v1.1.1` ➔
`ghcr.io/home-operations/vchord:1.3.0`, `Database` pin `1.1.1` ➔ `1.3.0`).

What changes: the extension goes 1.1.1 ➔ 1.2.0 ➔ 1.3.0 in one `ALTER EXTENSION vchord UPDATE`
(upstream ships `1.1.1--1.2.0` and `1.2.0--1.3.0` scripts; CNPG runs it when the `Database`
version pin moves). The index on-disk format is unchanged, so existing indexes keep working
without a rebuild. A rebuild is only recommended when an index contains zero-norm or otherwise
invalid vectors (RaBitQ metadata was NaN before 1.2.0), or on fp16-capable CPUs with large
`halfvec` magnitudes. 1.3.0 also corrects RaBitQ cosine semantics and invalid-direction
handling. Release notes: <https://github.com/pgsty/vchord/releases/tag/1.2.0> and
<https://github.com/pgsty/vchord/releases/tag/1.3.0>.

There is **no downgrade script**. Once the `Database` pin is applied, going back means
restoring from backup, see [Rollback](#rollback). Do not treat a manifest revert as a downgrade.

Shorthand used below:

```bash
PSQL="kubectl exec -n kritika-system kritika-postgres-1 -c postgres -- psql -d kritika -X"
```

Use the current primary (`kubectl get cluster -n kritika-system kritika-postgres`) in place of
`kritika-postgres-1`.

## 1. Preflight (before merging the PR)

1. Confirm the starting state:

   ```bash
   $PSQL -Atc "select extname, extversion from pg_extension where extname in ('vector','vchord')"
   # vchord must be 1.1.1
   ```

2. Check every physical `index_chunks` partition for NULL, zero-norm, NaN or infinite
   embeddings. `index_chunks` is a partitioned table, and each physical partition
   (`index_chunks_00` … `index_chunks_63`) carries its own `halfvec_cosine_ops` vchordrq index,
   so check per partition:

   ```sql
   select tablename,
          (xpath('/row/bad/text()', query_to_xml(format($q$
            select count(*) filter (where embedding is not null
                   and (l2_norm(embedding) = 0 or l2_norm(embedding)::text in ('NaN','Infinity'))) bad
            from %I.%I$q$, schemaname, tablename), false, true, '')))[1]::text::bigint as bad_rows
   from pg_tables
   where tablename ~ '^index_chunks_[0-9]{2}$'
   order by bad_rows desc, tablename;
   ```

   Cross-check that the partitions you scanned cover all rows:
   `select count(*) from index_chunks` must equal the sum of the per-partition counts.

   Last run against the live cluster before this PR: 595 rows, 0 NULL / zero-norm / invalid.

3. If **any** partition has `bad_rows > 0`, plan a rebuild of exactly those partitions' indexes
   (step 4 below) in addition to the upgrade. Consider fixing or re-embedding the bad rows
   first, since a zero vector still ranks unpredictably under cosine distance.

4. Record a baseline for the similarity check: for a few representative partitions, save the
   top-10 ids for a stored vector.

   ```sql
   select id from index_chunks_07
   order by embedding <=> (select embedding from index_chunks_07 order by id limit 1)
   limit 10;
   ```

5. Take and verify the backup from [Rollback](#rollback). **Do not merge until it is verified.**

## 2. Upgrade

Merge the PR and watch the rollout:

```bash
kubectl get cluster -n kritika-system kritika-postgres -w
kubectl get database -n kritika-system kritika -o yaml   # status.applied: true
```

## 3. Post-upgrade validation

Verify the extension version first. Everything below requires it:

```bash
$PSQL -Atc "select extversion from pg_extension where extname = 'vchord'"   # must be 1.3.0
```

Then run the baseline queries from step 1.4 and compare:

- the result overlaps the saved top-10 (identical or near-identical; large differences are a
  failure),
- the plan uses the index: `explain select … order by embedding <=> … limit 10` shows
  `Index Scan using index_chunks_NN_embedding_idx`,
- kritika itself serves a search without errors.

If validation fails, go to [Rollback](#rollback).

## 4. Concurrent rebuild (only if preflight found bad rows)

Only after `extversion` is confirmed as `1.3.0`. Rebuild the physical indexes (indexes on a
partitioned parent cannot be reindexed concurrently, so work on the per-partition indexes) one at
a time:

```sql
-- list the affected partitions' indexes, then run each:
REINDEX INDEX CONCURRENTLY public.index_chunks_07_embedding_idx;
```

After each rebuild check `indisvalid` is true (a failed concurrent rebuild leaves an invalid
`_ccnew` index to drop), then repeat the representative similarity query against that partition:

```sql
select indexrelid::regclass, indisvalid from pg_index
where indexrelid::regclass::text ~ '^index_chunks_[0-9]{2}_embedding_idx';
```
