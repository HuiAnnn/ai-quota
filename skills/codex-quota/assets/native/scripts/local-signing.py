#!/usr/bin/env python3
"""Keep this personal companion's signing identity stable between builds."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

SUBJECT = "AI Quota Local Signing"
BUNDLE_ID = "local.huian.codex-quota"
KEYCHAIN = str(Path.home() / "Library/Keychains/login.keychain-db")
STATE_DIR = Path.home() / "Library/Application Support/CodexQuota/Signing"
SECURITY, OPENSSL = "/usr/bin/security", "/usr/bin/openssl"
CONFIG_KEYS = {"version", "fingerprint", "keychain", "bundle_id"}
KEY_NOT_FOUND = "security: SecItemCopyMatching: The specified item could not be found in the keychain."
RECOVERY = "已有本地签名记录不完整，请恢复原证书和私钥；不要删除记录后重新生成身份。"


def run_command(args, check=True):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=180,
                                env={**os.environ, "LC_ALL": "C"})
    except (OSError, subprocess.SubprocessError):
        raise SigningError("本地签名命令未完成，请检查系统授权。") from None
    if check and result.returncode:
        # Never include subprocess arguments, stderr, or key material in errors.
        raise SigningError("本地签名命令未完成，请检查系统授权。")
    return result


class SigningError(Exception):
    pass


class SigningManager:
    def __init__(self, state_dir=None, runner=None, emit=None):
        self.state_dir = Path(state_dir) if state_dir is not None else STATE_DIR
        self.run = runner or run_command
        self.emit = emit or print
        self.config_path = self.state_dir / "identity.json"
        self.certificate_path = self.state_dir / "certificate.cer"
        self.pending_path = self.state_dir / "pending.json"

    @staticmethod
    def read_regular(path, maximum):
        if not path.exists() or path.is_symlink():
            raise SigningError(RECOVERY)
        metadata = path.stat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_size > maximum:
            raise SigningError(RECOVERY)
        return path.read_bytes()

    def available_identities(self):
        output = self.run([SECURITY, "find-identity", "-v", "-p", "codesigning", KEYCHAIN]).stdout
        entries = re.findall(r'^\s*\d+\)\s+([a-fA-F0-9]{40})\s+"([^"]+)"\s*$', output, re.MULTILINE)
        return {fingerprint.upper() for fingerprint, name in entries if name == SUBJECT}

    def identity(self):
        if not self.config_path.exists():
            raise SigningError("尚未配置固定签名身份，请先运行 local-signing.py setup。")
        try:
            config = json.loads(self.read_regular(self.config_path, 4096))
        except (ValueError, UnicodeError):
            raise SigningError(RECOVERY) from None
        if (not isinstance(config, dict) or set(config) != CONFIG_KEYS or type(config["version"]) is not int
                or config["version"] != 1 or config["bundle_id"] != BUNDLE_ID or config["keychain"] != KEYCHAIN
                or not isinstance(config["fingerprint"], str)
                or not re.fullmatch(r"[A-F0-9]{40}", config["fingerprint"])):
            raise SigningError(RECOVERY)
        certificate = self.read_regular(self.certificate_path, 16384)
        if hashlib.sha1(certificate).hexdigest().upper() != config["fingerprint"]:
            raise SigningError(RECOVERY)
        expiry = self.run([OPENSSL, "x509", "-inform", "DER", "-in", str(self.certificate_path),
                           "-checkend", "0", "-noout"], check=False)
        if expiry.returncode:
            raise SigningError("固定签名证书已失效或无法识别，请修复原签名身份；不会重新生成或使用临时签名。")
        if config["fingerprint"] not in self.available_identities():
            raise SigningError("钥匙串中缺少可用的原签名身份，请恢复原证书和私钥；不会重新生成或使用临时签名。")
        return config["fingerprint"]

    @staticmethod
    def write_metadata(path, data):
        temporary = path.with_suffix(path.suffix + ".tmp")
        with temporary.open("xb") as output:
            os.chmod(temporary, 0o600)
            output.write(data)
        temporary.replace(path)

    def setup(self):
        if any(path.is_symlink() for path in (self.config_path, self.pending_path, self.certificate_path)):
            raise SigningError(RECOVERY)
        if self.config_path.exists():
            fingerprint = self.identity()
            self.emit("已验证原固定签名身份，未生成新证书。")
            return fingerprint
        if self.pending_path.exists() or self.certificate_path.exists():
            raise SigningError(RECOVERY)
        # A matching orphaned certificate/key requires manual recovery, not a new key.
        for query in ([SECURITY, "find-certificate", "-c", SUBJECT, "-Z", KEYCHAIN],
                      [SECURITY, "find-key", "-l", SUBJECT, "-s", "-t", "private", KEYCHAIN]):
            result = self.run(query, check=False)
            if result.returncode == 0:
                raise SigningError(RECOVERY)
            key_missing = (query[1] == "find-key" and result.returncode == 1
                           and result.stderr.strip() == KEY_NOT_FOUND)
            if result.returncode != 44 and not key_missing:
                raise SigningError("无法确认钥匙串签名状态，请解锁登录钥匙串后重试；未生成新身份。")
        if self.state_dir.is_symlink():
            raise SigningError(RECOVERY)
        self.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        if self.state_dir.stat().st_uid != os.getuid():
            raise SigningError(RECOVERY)
        os.chmod(self.state_dir, 0o700)
        previous_umask = os.umask(0o077)
        try:
            with tempfile.TemporaryDirectory(prefix="ai-quota-signing-") as temporary:
                folder = Path(temporary)
                os.chmod(folder, 0o700)
                key, certificate, der, configuration = (folder / name for name in
                                                       ("private.pem", "certificate.pem", "certificate.cer", "openssl.cnf"))
                configuration.write_text("[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=codesign\n"
                                         f"[dn]\nCN={SUBJECT}\n[codesign]\nbasicConstraints=critical,CA:FALSE\n"
                                         "keyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n"
                                         "subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n")
                self.emit("正在创建仅用于代码签名的本地证书。")
                self.run([OPENSSL, "genrsa", "-out", str(key), "2048"])
                os.chmod(key, 0o600)
                self.run([OPENSSL, "req", "-new", "-x509", "-sha256", "-days", "3650", "-key", str(key),
                          "-out", str(certificate), "-config", str(configuration)])
                self.run([OPENSSL, "x509", "-in", str(certificate), "-outform", "DER", "-out", str(der)])
                public_certificate = der.read_bytes()
                fingerprint = hashlib.sha1(public_certificate).hexdigest().upper()
                metadata = json.dumps(dict(version=1, fingerprint=fingerprint, keychain=KEYCHAIN,
                                           bundle_id=BUNDLE_ID), indent=2).encode() + b"\n"
                self.write_metadata(self.certificate_path, public_certificate)
                self.write_metadata(self.pending_path, metadata)
                self.emit("正在导入登录钥匙串；若系统要求，请完成此次授权。")
                # Unwrapped temporary PEM avoids putting an import password in process arguments.
                self.run([SECURITY, "import", str(key), "-k", KEYCHAIN, "-f", "openssl", "-t", "priv",
                          "-x", "-T", "/usr/bin/codesign"])
                self.run([SECURITY, "import", str(der), "-k", KEYCHAIN, "-f", "x509", "-t", "cert"])
                if fingerprint not in self.available_identities():
                    self.emit("正在设置当前用户的代码签名信任；若系统要求，请完成此次授权。")
                    self.run([SECURITY, "add-trusted-cert", "-r", "trustRoot", "-p", "codeSign",
                              "-k", KEYCHAIN, str(der)])
                if fingerprint not in self.available_identities():
                    raise SigningError("导入后的固定签名身份不可用。" + RECOVERY)
                self.write_metadata(self.config_path, metadata)
                self.pending_path.unlink()
        finally:
            os.umask(previous_umask)
        self.emit("固定签名身份设置完成；之后的构建将复用该身份。")
        return self.identity()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("setup", "identity"))
    arguments = parser.parse_args()
    try:
        manager = SigningManager()
        if arguments.command == "identity":
            print(manager.identity())
        else:
            manager.setup()
    except (SigningError, OSError) as error:
        message = str(error) if isinstance(error, SigningError) else "无法访问本地签名记录，请检查文件权限。"
        print(message, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
