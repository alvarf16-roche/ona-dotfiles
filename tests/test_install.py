"""Exercise the installer in a temporary home with fake Nix and curl commands."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / "install.sh"
FAKE_COMMAND = """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

name = Path(sys.argv[0]).name
if name == "curl":
    header = sys.stdin.read().strip()
    token = header.removeprefix("Authorization: Bearer ")
    with open(os.environ["TEST_REQUESTS"], "a") as requests:
        requests.write(json.dumps({"token": token, "args": sys.argv[1:]}) + "\\n")
    status = json.loads(os.environ["TEST_TOKEN_STATUS"])[token]
    if status == "network-error":
        sys.exit(7)
    print(status, end="")
elif sys.argv[1:] == ["--version"]:
    print("nix (test)")
elif sys.argv[1:] == ["config", "show", "access-tokens"]:
    print(os.environ["TEST_NIX_ACCESS_TOKENS"])
elif sys.argv[1] == "run":
    # Reproduce public fetches failing when Nix forwards a rejected token.
    credentials = {}
    for line in os.environ.get("NIX_CONFIG", "").splitlines():
        if line.startswith("access-tokens ="):
            credentials = dict(entry.split("=", 1) for entry in line.split("=", 1)[1].split())
    statuses = json.loads(os.environ["TEST_TOKEN_STATUS"])
    for host, token in credentials.items():
        if host == "github.com" or host.startswith("github.com/"):
            if token in statuses and statuses[token] != "200":
                sys.exit("HTTP 401: rejected GitHub credential")
    Path(os.environ["TEST_RESULT"]).write_text(json.dumps({
        key: os.environ.get(key)
        for key in ("NIX_CONFIG", "GITHUB_TOKEN", "GITHUB_TOKEN_OSS", "GH_TOKEN")
    }))
else:
    sys.exit("unexpected nix invocation")
"""


class InstallerTests(unittest.TestCase):
    def run_installer(self, *, tokens=None, statuses=None, nix_config=None,
                      existing_tokens=""):
        tokens = tokens or {}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            home = root / "home"
            home.mkdir()
            bin_dir = root / "bin"
            bin_dir.mkdir()
            for command in ("nix", "curl"):
                script = bin_dir / command
                script.write_text(FAKE_COMMAND)
                script.chmod(0o755)

            env = os.environ.copy()
            for key in ("GITHUB_TOKEN", "GITHUB_TOKEN_OSS", "GITHUB_TOKEN_ENTERPRISE",
                        "GH_TOKEN", "NIX_CONFIG", "ZDOTDIR", "XDG_CONFIG_HOME"):
                env.pop(key, None)
            env.update({
                "HOME": str(home),
                "PATH": f"{bin_dir}:{env['PATH']}",
                "TEST_REQUESTS": str(root / "requests.jsonl"),
                "TEST_RESULT": str(root / "result.json"),
                "TEST_TOKEN_STATUS": json.dumps(statuses or {}),
                "TEST_NIX_ACCESS_TOKENS": existing_tokens,
                **tokens,
            })
            if nix_config is not None:
                env["NIX_CONFIG"] = nix_config
            completed = subprocess.run(
                ["bash", str(INSTALLER)], env=env, text=True, capture_output=True,
                timeout=10,
            )
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            result = json.loads((root / "result.json").read_text())
            requests_file = root / "requests.jsonl"
            requests = ([json.loads(line) for line in requests_file.read_text().splitlines()]
                        if requests_file.exists() else [])

            # Credentials must stay out of logs, argv, and persistent configuration.
            for token in tokens.values():
                if not token:
                    continue
                self.assertNotIn(token, completed.stdout + completed.stderr)
                self.assertNotIn(token, (home / ".dotfiles-install.log").read_text())
                self.assertNotIn(token, (home / ".config/nix/nix.conf").read_text())
                for request in requests:
                    self.assertNotIn(token, " ".join(request["args"]))
            for request in requests:
                self.assertIn("@-", request["args"])
                self.assertEqual(request["args"][-1],
                                 "https://api.github.com/repos/javier-varez/nixvim-cfg")
            for key in ("GITHUB_TOKEN", "GITHUB_TOKEN_OSS", "GH_TOKEN"):
                self.assertEqual(result[key], tokens.get(key))
            self.assertIn("[dotfiles] done", completed.stdout)
            return result, requests, completed.stdout

    def test_no_environment_tokens_preserves_nix_config(self):
        original = "access-tokens = github.com=configured-token\nmax-jobs = 2"
        result, requests, _ = self.run_installer(nix_config=original)
        self.assertEqual(result["NIX_CONFIG"], original)
        self.assertEqual(requests, [])

    def test_no_tokens_or_nix_config(self):
        result, requests, _ = self.run_installer()
        self.assertIsNone(result["NIX_CONFIG"])
        self.assertEqual(requests, [])

    def test_empty_tokens_are_unset(self):
        result, requests, _ = self.run_installer(
            tokens={"GITHUB_TOKEN_OSS": "", "GITHUB_TOKEN": ""},
        )
        self.assertIsNone(result["NIX_CONFIG"])
        self.assertEqual(requests, [])

    def test_oss_preferred_and_existing_other_host_credentials_preserved(self):
        original = "access-tokens = github.com=old-token gitlab.com=PAT:other\nmax-jobs = 2"
        result, requests, _ = self.run_installer(
            tokens={"GITHUB_TOKEN_OSS": "valid-oss", "GITHUB_TOKEN": "enterprise-token",
                    "GH_TOKEN": "cli-token"},
            statuses={"valid-oss": "200"}, nix_config=original,
            existing_tokens="github.com=old-token github.com/org=old-scoped "
                            "gitlab.com=PAT:other",
        )
        self.assertEqual([request["token"] for request in requests], ["valid-oss"])
        self.assertEqual(result["NIX_CONFIG"],
                         original + "\naccess-tokens = github.com=valid-oss gitlab.com=PAT:other")

    def test_valid_generic_token(self):
        result, _, _ = self.run_installer(
            tokens={"GITHUB_TOKEN": "valid-generic"}, statuses={"valid-generic": "200"},
        )
        self.assertEqual(result["NIX_CONFIG"], "access-tokens = github.com=valid-generic")

    def test_rejected_oss_falls_back_to_generic(self):
        result, requests, output = self.run_installer(
            tokens={"GITHUB_TOKEN_OSS": "expired-oss", "GITHUB_TOKEN": "valid-generic"},
            statuses={"expired-oss": "401", "valid-generic": "200"},
        )
        self.assertEqual([request["token"] for request in requests],
                         ["expired-oss", "valid-generic"])
        self.assertEqual(result["NIX_CONFIG"], "access-tokens = github.com=valid-generic")
        self.assertIn("HTTP 401", output)

    def test_rejected_tokens_use_anonymous_fetches(self):
        result, _, output = self.run_installer(
            tokens={"GITHUB_TOKEN_OSS": "forbidden-oss", "GITHUB_TOKEN": "expired-generic"},
            statuses={"forbidden-oss": "403", "expired-generic": "401"},
            existing_tokens="github.com=old-token github.com/org=old-scoped "
                            "gitlab.com=PAT:other",
        )
        self.assertEqual(result["NIX_CONFIG"], "access-tokens = gitlab.com=PAT:other")
        self.assertIn("without authentication", output)

    def test_rejected_generic_token_with_no_existing_credentials(self):
        result, _, _ = self.run_installer(
            tokens={"GITHUB_TOKEN": "expired-generic"}, statuses={"expired-generic": "401"},
        )
        self.assertEqual(result["NIX_CONFIG"], "access-tokens = ")

    def test_network_error_does_not_abort_installation(self):
        result, _, output = self.run_installer(
            tokens={"GITHUB_TOKEN": "unchecked-generic"},
            statuses={"unchecked-generic": "network-error"},
        )
        self.assertEqual(result["NIX_CONFIG"], "access-tokens = ")
        self.assertIn("could not check GITHUB_TOKEN", output)

    def test_network_error_can_fall_back_to_generic(self):
        result, requests, _ = self.run_installer(
            tokens={"GITHUB_TOKEN_OSS": "unchecked-oss", "GITHUB_TOKEN": "valid-generic"},
            statuses={"unchecked-oss": "network-error", "valid-generic": "200"},
        )
        self.assertEqual(len(requests), 2)
        self.assertEqual(result["NIX_CONFIG"], "access-tokens = github.com=valid-generic")


if __name__ == "__main__":
    unittest.main()
