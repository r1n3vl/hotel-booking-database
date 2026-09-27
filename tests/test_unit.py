import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from tools.db import load_env, quote_identifier, split_batches, drop_test_database


class RunnerTests(unittest.TestCase):
    def test_batch_separator_and_comments(self):
        self.assertEqual(split_batches('SELECT 1;\ngo -- next batch\nSELECT 2;\nGO\n'), ['SELECT 1;', 'SELECT 2;'])

    def test_go_inside_line_is_not_separator(self):
        self.assertEqual(split_batches("SELECT 'GO';\n"), ["SELECT 'GO';"])

    def test_empty_batches_are_ignored(self):
        self.assertEqual(split_batches('GO\nGO\nSELECT 1;\nGO'), ['SELECT 1;'])

    def test_sqlcmd_directives_are_rejected(self):
        with self.assertRaises(ValueError):
            split_batches(':r other.sql')

    def test_go_repetition_is_rejected(self):
        with self.assertRaises(ValueError):
            split_batches('SELECT 1;\nGO 2')

    def test_identifier(self):
        self.assertEqual(quote_identifier('HotelBooking_2'), '[HotelBooking_2]')

    def test_unsafe_identifiers(self):
        for value in ['x]; DROP DATABASE master;--', '', 'a.b', '9name', 'a'*61, 'ホテル']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                quote_identifier(value)

    def test_drop_guard_rejects_application_database(self):
        with self.assertRaises(ValueError):
            drop_test_database('HotelBooking')

    def test_environment_does_not_override_existing_values(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / '.env'
            path.write_text("# local\nAPP_TEST_A='literal_$value!'\nAPP_TEST_B=file\n", encoding='utf-8')
            with patch.dict(os.environ, {'APP_TEST_B': 'existing'}, clear=True):
                load_env(path)
                self.assertEqual(os.environ['APP_TEST_A'], 'literal_$value!')
                self.assertEqual(os.environ['APP_TEST_B'], 'existing')

    def test_invalid_env_entry(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / '.env'
            path.write_text('not_an_assignment', encoding='utf-8')
            with self.assertRaises(ValueError):
                load_env(path)


if __name__ == '__main__':
    unittest.main()
