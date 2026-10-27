"""Isolation guards for the shared-cluster refund reset."""
import importlib.util
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))
spec = importlib.util.spec_from_file_location('refund_reset', Path(__file__).with_name('reset.py'))
reset = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reset)


class RefundResetTests(unittest.TestCase):
    def test_history_scope_includes_only_the_six_bank_agents(self):
        self.assertEqual(len(reset.AGENT_IDS), 6)
        self.assertTrue(all(name.startswith('bank__NS__') for name in reset.AGENT_IDS))
        sql = reset.postgres_reset_sql()
        self.assertIn('BEGIN;', sql)
        self.assertIn('COMMIT;', sql)
        self.assertNotIn('deleted_at IS NULL', sql, 'Soft-deleted prompts must also be purged')
        self.assertNotIn('TRUNCATE', sql)
        self.assertNotIn('DELETE FROM agent ', sql)
        for line in sql.splitlines():
            if line.startswith('DELETE FROM'):
                self.assertIn('USING refund_reset_', line)

    def test_empty_or_invalid_trace_scope_never_becomes_a_table_wipe(self):
        self.assertEqual(list(reset.trace_delete_queries(set())), [])
        with self.assertRaises(ValueError):
            list(reset.trace_delete_queries({'not-a-trace'}))
        queries = list(reset.trace_delete_queries({'a' * 32}))
        self.assertEqual(len(queries), len(reset.TRACE_TABLES))
        self.assertTrue(all("WHERE TraceId IN ('" + 'a' * 32 + "')" in q for q in queries))
        self.assertTrue(all('mutations_sync=2' in q for q in queries))
        self.assertNotIn('otel_k8sobjects_json', reset.TRACE_TABLES)

    def test_unowned_namespace_stops_before_deleting_any_data(self):
        with patch.object(reset, 'kube', return_value=json.dumps({'metadata': {'labels': {}}})), \
             patch.object(reset, 'postgres') as pg, patch.object(reset, 'clickhouse') as ch:
            with self.assertRaisesRegex(RuntimeError, 'not owned'):
                reset.reset()
            pg.assert_not_called()
            ch.assert_not_called()


if __name__ == '__main__':
    unittest.main()
