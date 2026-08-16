"""VCAM License Generator — PySide6 desktop UI."""
import os
import sys
import json
import importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))

# gen-license.py uses a hyphen and cannot be imported as a normal module.
_spec = importlib.util.spec_from_file_location("gen_license", os.path.join(HERE, "gen-license.py"))
_gen_license_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_gen_license_mod)
gen_license = _gen_license_mod.gen_license
license_b64 = _gen_license_mod.license_b64
license_plist_bytes = _gen_license_mod.license_plist_bytes

from PySide6.QtCore import QDate
from PySide6.QtWidgets import (
    QApplication,
    QDateEdit,
    QFileDialog,
    QFormLayout,
    QGroupBox,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QPushButton,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

STATE_FILE = os.path.join(HERE, ".license-ui-state.json")
SSH_KEY = os.path.normpath(os.path.join(HERE, "..", "dist", "trollvnc", "ssh", "id_ed25519"))
DEVICE_LICENSE_PATH = "/var/mobile/Media/VCAM/license.plist"


def load_state():
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def save_state(state):
    try:
        with open(STATE_FILE, "w", encoding="utf-8") as f:
            json.dump(state, f, ensure_ascii=False, indent=2)
    except Exception:
        pass


class LicenseWindow(QWidget):
    def __init__(self):
        super().__init__()
        self._license = None
        self._b64 = ""
        self._build_ui()
        self._restore_state()

    def _build_ui(self):
        self.setWindowTitle("VCAM 授权生成器")
        self.resize(540, 640)

        root = QVBoxLayout(self)

        form = QFormLayout()
        self.udid_edit = QLineEdit()
        self.udid_edit.setPlaceholderText("设备 UDID（面板“复制设备ID”）")
        form.addRow("设备 UDID", self.udid_edit)

        self.expiry_edit = QDateEdit()
        self.expiry_edit.setDisplayFormat("yyyy-MM-dd")
        self.expiry_edit.setCalendarPopup(True)
        self.expiry_edit.setDate(QDate(2099, 12, 31))
        form.addRow("到期日", self.expiry_edit)
        root.addLayout(form)

        self.generate_btn = QPushButton("生成授权")
        self.generate_btn.clicked.connect(self._on_generate)
        root.addWidget(self.generate_btn)

        self.status_label = QLabel("")
        self.status_label.setWordWrap(True)
        root.addWidget(self.status_label)

        out_group = QGroupBox("授权码")
        out_layout = QVBoxLayout(out_group)
        self.b64_edit = QTextEdit()
        self.b64_edit.setReadOnly(True)
        self.b64_edit.setPlaceholderText("点击“生成授权”后显示 base64 授权码")
        out_layout.addWidget(self.b64_edit)

        out_btns = QHBoxLayout()
        self.copy_btn = QPushButton("复制授权码")
        self.copy_btn.setEnabled(False)
        self.copy_btn.clicked.connect(self._on_copy)
        self.save_btn = QPushButton("保存 license.plist")
        self.save_btn.setEnabled(False)
        self.save_btn.clicked.connect(self._on_save)
        out_btns.addWidget(self.copy_btn)
        out_btns.addWidget(self.save_btn)
        out_layout.addLayout(out_btns)
        root.addWidget(out_group)

        deploy_group = QGroupBox("部署到设备")
        deploy_layout = QFormLayout(deploy_group)
        self.ip_edit = QLineEdit()
        self.ip_edit.setPlaceholderText("设备 IP，如 192.168.2.101")
        deploy_layout.addRow("设备 IP", self.ip_edit)
        self.password_edit = QLineEdit()
        self.password_edit.setEchoMode(QLineEdit.Password)
        self.password_edit.setPlaceholderText("root 密码（留空则用本地密钥）")
        deploy_layout.addRow("密码", self.password_edit)
        root.addWidget(deploy_group)

        self.deploy_btn = QPushButton("部署到设备")
        self.deploy_btn.setEnabled(False)
        self.deploy_btn.clicked.connect(self._on_deploy)
        root.addWidget(self.deploy_btn)

    def _set_status(self, text, error=False):
        self.status_label.setText(text)
        self.status_label.setStyleSheet("color: #d33;" if error else "color: #2a2;")

    def _restore_state(self):
        state = load_state()
        if state.get("last_udid"):
            self.udid_edit.setText(state["last_udid"])
        if state.get("last_ip"):
            self.ip_edit.setText(state["last_ip"])

    def _persist_state(self):
        state = load_state()
        state["last_udid"] = self.udid_edit.text().strip()
        state["last_ip"] = self.ip_edit.text().strip()
        save_state(state)

    def _on_generate(self):
        udid = self.udid_edit.text().strip().upper()
        if not udid:
            self._set_status("错误：请先填写设备 UDID", error=True)
            return
        expiry = self.expiry_edit.date().toString("yyyy-MM-dd")
        try:
            self._license = gen_license(udid, expiry)
            self._b64 = license_b64(self._license)
        except Exception as exc:
            self._set_status("生成失败：%s" % exc, error=True)
            return
        self.b64_edit.setPlainText(self._b64)
        self.copy_btn.setEnabled(True)
        self.save_btn.setEnabled(True)
        self.deploy_btn.setEnabled(True)
        self._set_status("已生成（到期 %s）" % expiry)
        self._persist_state()

    def _on_copy(self):
        if not self._b64:
            return
        QApplication.clipboard().setText(self._b64)
        self._set_status("授权码已复制到剪贴板")

    def _on_save(self):
        if self._license is None:
            return
        path, _ = QFileDialog.getSaveFileName(
            self, "保存 license.plist", "license.plist", "Plist (*.plist);;所有文件 (*)"
        )
        if not path:
            return
        try:
            with open(path, "wb") as f:
                f.write(license_plist_bytes(self._license))
            self._set_status("已保存到 %s" % path)
        except Exception as exc:
            self._set_status("保存失败：%s" % exc, error=True)

    def _on_deploy(self):
        if self._license is None:
            self._set_status("错误：请先生成授权", error=True)
            return
        ip = self.ip_edit.text().strip()
        if not ip:
            self._set_status("错误：请填写设备 IP", error=True)
            return
        try:
            import paramiko
        except ImportError:
            self._set_status("错误：缺少 paramiko，无法部署", error=True)
            return

        self._set_status("正在部署…")
        QApplication.processEvents()

        key_file = SSH_KEY if os.path.exists(SSH_KEY) else None
        password = self.password_edit.text()
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        try:
            client.connect(
                ip,
                username="root",
                password=password or None,
                key_filename=key_file,
                timeout=10,
                look_for_keys=False,
                allow_agent=False,
            )
        except Exception as exc:
            self._set_status("连接失败：%s" % exc, error=True)
            return

        try:
            sftp = client.open_sftp()
            with sftp.open(DEVICE_LICENSE_PATH, "wb") as f:
                f.write(license_plist_bytes(self._license))
            client.exec_command(
                "chown mobile:mobile %s; chmod 644 %s; "
                "sbreload 2>/dev/null || killall -9 SpringBoard 2>/dev/null"
                % (DEVICE_LICENSE_PATH, DEVICE_LICENSE_PATH)
            )
            self._set_status("已部署并 respring")
            self._persist_state()
        except Exception as exc:
            self._set_status("部署失败：%s" % exc, error=True)
        finally:
            client.close()


def main():
    app = QApplication(sys.argv)
    win = LicenseWindow()
    win.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
