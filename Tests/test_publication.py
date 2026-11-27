import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / "Scripts"
sys.path.insert(0, str(SCRIPTS))
from check_dmg import APP, audit
from check_publication import findings


class PublicationTests(unittest.TestCase):
    def test_private_payloads(self):
        for value in (b"password" + b" = 'synthetic-canary'", b"person" + b"@mail.example.org",
                      b"https://jira." + b"company.internal", b"/Users" + b"/fixture/private"):
            self.assertTrue(findings(value, "config"))
        self.assertTrue(findings(b"\x00redacted-canary", "asset", [b"redacted-canary"], binary=True))

    def test_unexpected_dmg_entries(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / APP).mkdir()
            (root / "Applications").symlink_to("/Applications")
            (root / APP / "private-config").write_text("fixture")
            with self.assertRaisesRegex(ValueError, "Unexpected bundle entry"):
                audit(root)

    def test_hooks_block_staged_and_outgoing_data(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "work"
            repo.mkdir()
            env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
            for key in list(env):
                if key.startswith(("GIT_AUTHOR_", "GIT_COMMITTER_")) or key == "OC_PUBLICATION_DENY_FILE":
                    del env[key]
            def git(*args, ok=True):
                result = subprocess.run(["git", *args], cwd=repo, env=env, capture_output=True)
                self.assertEqual(result.returncode == 0, ok, "unexpected Git policy result")
                self.assertNotIn(b"synthetic-canary", result.stderr)
            git("init", "-q")
            (repo / "Scripts").symlink_to(SCRIPTS, target_is_directory=True)
            git("config", "core.hooksPath", str(SCRIPTS.parent / ".githooks"))
            git("config", "user.name", "Fixture")
            git("config", "user.email", "fixture@users.noreply.github.com")
            doc = repo / "README"
            doc.write_text("clean")
            git("add", "README")
            git("commit", "-qm", "clean")
            git("init", "--bare", "-q", "../remote")
            git("push", "../remote", "HEAD:refs/heads/main")
            git("config", "user.email", "fixture" + "@company.example.org")
            git("commit", "--allow-empty", "-qm", "identity", ok=False)
            git("config", "user.email", "fixture@users.noreply.github.com")
            for payload in ["password" + " = 'synthetic-canary'", "https://jira." + "company.internal",
                            "/Users" + "/fixture/private"]:
                doc.write_text(payload)
                git("add", "README")
                git("commit", "-qm", "fixture", ok=False)
            git("-c", "core.hooksPath=/dev/null", "commit", "-qm", "intermediate")
            doc.write_text("clean")
            git("add", "README")
            git("commit", "-qm", "restore")
            git("push", "../remote", "HEAD:refs/heads/main", ok=False)
