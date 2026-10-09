import os
import struct
import sys
import threading
import time

import cv2
import numpy as np
from PyQt5.QtCore import Qt, QThread, pyqtSignal
from PyQt5.QtGui import QIcon, QImage, QPixmap
from PyQt5.QtWidgets import (QApplication, QComboBox, QFrame, QHBoxLayout, QLabel,
                             QMainWindow, QVBoxLayout, QWidget)

import usbmux

PORT = 9999
CAM_NAME = "HD Camera USC-CAM"          # name of the virtual webcam (see Install-HD-Camera.bat)
RESOLUTIONS = [("Native (as sent by iPhone)", None),
               ("3840x2160  (4K UHD)", (3840, 2160)),
               ("2560x1440  (QHD)", (2560, 1440)),
               ("1920x1080  (FHD)", (1920, 1080)),
               ("1280x720  (HD)", (1280, 720))]


def resource_path(name):
    base = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base, name)


def dshow_camera_installed(name):
    """True if a DirectShow video device with this friendly name is registered."""
    if sys.platform != "win32":
        return False
    import winreg
    path = r"CLSID\{860BB310-5D01-11d0-BD3B-00A0C911CE86}\Instance"
    try:
        root = winreg.OpenKey(winreg.HKEY_CLASSES_ROOT, path)
    except OSError:
        return False
    i = 0
    while True:
        try:
            sub = winreg.EnumKey(root, i)
        except OSError:
            return False
        i += 1
        try:
            with winreg.OpenKey(root, sub) as k:
                if winreg.QueryValueEx(k, "FriendlyName")[0] == name:
                    return True
        except OSError:
            pass


def open_camera(w, h):
    """Opens the virtual camera. Prefers 'HD Camera USC-CAM' (Unity Capture driver),
    falls back to 'OBS Virtual Camera'. Returns (camera, display_name, swap_rb)."""
    import pyvirtualcam
    backends = []
    if dshow_camera_installed(CAM_NAME):
        backends.append(("unitycapture", CAM_NAME))
    backends.append(("obs", "OBS Virtual Camera"))
    last = None
    for backend, name in backends:
        for fmt, swap in ((pyvirtualcam.PixelFormat.BGR, False),
                          (pyvirtualcam.PixelFormat.RGB, True)):
            try:
                cam = pyvirtualcam.Camera(width=w, height=h, fps=30, fmt=fmt, backend=backend)
                return cam, name, swap
            except Exception as e:      # noqa: BLE001 - try next backend/format
                last = e
    raise RuntimeError(last)


class FrameReceiver(threading.Thread):
    """Drains the USB socket as fast as possible and keeps ONLY the newest frame.
    This is what removes the lag: old frames are dropped instead of queued up."""

    def __init__(self, sock):
        super().__init__(daemon=True)
        self.sock = sock
        self.cond = threading.Condition()
        self.latest = None
        self.dead = False
        self.halt = False

    def run(self):
        try:
            while not self.halt:
                size = struct.unpack(">I", usbmux.recv_exact(self.sock, 4))[0]
                if size == 0 or size > 64 * 1024 * 1024:
                    raise ConnectionError("bad frame header")
                data = usbmux.recv_exact(self.sock, size)
                with self.cond:
                    self.latest = data          # overwrites an unprocessed older frame
                    self.cond.notify()
        except Exception:                        # noqa: BLE001 - any error ends the stream
            pass
        finally:
            with self.cond:
                self.dead = True
                self.cond.notify_all()

    def get(self, timeout=0.5):
        with self.cond:
            if self.latest is None and not self.dead:
                self.cond.wait(timeout)
            data, self.latest = self.latest, None
            return data


class StreamWorker(QThread):
    status = pyqtSignal(str, str)      # text, state: wait | live | error
    stats = pyqtSignal(str)
    preview = pyqtSignal(QImage)

    def __init__(self):
        super().__init__()
        self._running = True
        self.target = None             # None = native, or (w, h)

    def stop(self):
        self._running = False

    # -- main loop: find phone -> open tunnel -> stream -> repeat
    def run(self):
        while self._running:
            try:
                devices = usbmux.list_usb_devices()
            except OSError:
                self.status.emit("Apple USB driver not found - install iTunes or Apple Devices", "error")
                self._sleep(2)
                continue
            if not devices:
                self.status.emit("Connect your iPhone with a USB cable", "wait")
                self._sleep(1.5)
                continue
            try:
                sock = usbmux.connect(devices[0], PORT)
            except (usbmux.UsbmuxError, OSError):
                self.status.emit("Open the USC-CAM app on your iPhone (and tap Trust)", "wait")
                self._sleep(1.5)
                continue
            try:
                self._stream(sock)
            except (OSError, ConnectionError, struct.error):
                pass
            finally:
                sock.close()
            self.stats.emit("")

    def _sleep(self, seconds):
        end = time.time() + seconds
        while self._running and time.time() < end:
            time.sleep(0.05)

    def _stream(self, sock):
        rx = FrameReceiver(sock)
        rx.start()
        cam = None
        cam_size = None
        cam_name = ""
        swap = False
        src_w = 0                      # width of the frames the phone sends (for fast reduced decode)
        frames = 0
        tick = time.time()
        n = 0
        try:
            while self._running:
                data = rx.get(0.5)
                if data is None:
                    if rx.dead:
                        raise ConnectionError("stream ended")
                    continue

                target = self.target
                # Downscaling to <= half size: let libjpeg decode at 1/2 scale (much faster than full 4K)
                flag = cv2.IMREAD_COLOR
                if target and src_w >= 2 * target[0]:
                    flag = cv2.IMREAD_REDUCED_COLOR_2
                frame = cv2.imdecode(np.frombuffer(data, np.uint8), flag)
                if frame is None:
                    continue
                src_w = frame.shape[1] * (2 if flag == cv2.IMREAD_REDUCED_COLOR_2 else 1)

                if target and (frame.shape[1], frame.shape[0]) != target:
                    frame = cv2.resize(frame, target, interpolation=cv2.INTER_LINEAR)
                h, w = frame.shape[:2]

                if cam is None or cam_size != (w, h):
                    if cam is not None:
                        cam.close()
                        cam = None
                    try:
                        cam, cam_name, swap = open_camera(w, h)
                    except Exception:
                        self.status.emit("Install OBS Studio once (virtual camera driver) or run Install-HD-Camera.bat", "error")
                        raise ConnectionError("no virtual camera")
                    cam_size = (w, h)
                    self.status.emit("LIVE  -  select '%s' in your app" % cam_name, "live")

                out = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB) if swap else frame
                cam.send(out)

                frames += 1
                n += 1
                if n % 6 == 0:
                    small = cv2.resize(frame, (400, int(400 * h / w)), interpolation=cv2.INTER_AREA)
                    rgb = cv2.cvtColor(small, cv2.COLOR_BGR2RGB)
                    img = QImage(rgb.data, rgb.shape[1], rgb.shape[0], rgb.strides[0],
                                 QImage.Format_RGB888).copy()
                    self.preview.emit(img)
                now = time.time()
                if now - tick >= 1:
                    self.stats.emit("%dx%d  -  %d fps" % (w, h, round(frames / (now - tick))))
                    frames, tick = 0, now
        finally:
            rx.halt = True
            if cam is not None:
                cam.close()


class MainWindow(QMainWindow):
    COLORS = {"wait": "#E8A33D", "live": "#3DDC84", "error": "#FF5A5A"}

    def __init__(self):
        super().__init__()
        self.setWindowTitle(CAM_NAME)
        self.setFixedSize(520, 600)
        icon_file = resource_path("icon.ico")
        if os.path.exists(icon_file):
            self.setWindowIcon(QIcon(icon_file))
        self.setStyleSheet("""
            QMainWindow { background-color: #0A0A0A; }
            QLabel { color: #FFFFFF; font-family: 'Segoe UI', sans-serif; }
            QLabel#Title { font-size: 24px; font-weight: bold; letter-spacing: 3px; }
            QLabel#Sub { font-size: 11px; color: #888888; font-weight: 600; letter-spacing: 3px; }
            QLabel#Stats { font-size: 13px; color: #BBBBBB; }
            QFrame#Pill { background-color: #1A1A1A; border-radius: 18px; }
            QLabel#Preview { background-color: #000000; border: 1px solid #262626; border-radius: 10px; }
            QComboBox { background-color: #1A1A1A; color: #FFFFFF; border: 1px solid #333333;
                        border-radius: 8px; padding: 10px 14px; font-size: 14px; font-weight: 600; }
            QComboBox::drop-down { border: none; }
            QComboBox QAbstractItemView { background-color: #1A1A1A; color: #FFFFFF;
                        selection-background-color: #333333; border: 1px solid #333333; }
        """)

        central = QWidget()
        root = QVBoxLayout(central)
        root.setContentsMargins(24, 24, 24, 24)
        root.setSpacing(14)

        title = QLabel(CAM_NAME)
        title.setObjectName("Title")
        title.setAlignment(Qt.AlignCenter)
        sub = QLabel("USB WEBCAM")
        sub.setObjectName("Sub")
        sub.setAlignment(Qt.AlignCenter)
        root.addWidget(title)
        root.addWidget(sub)

        self.preview = QLabel("No video yet")
        self.preview.setObjectName("Preview")
        self.preview.setAlignment(Qt.AlignCenter)
        self.preview.setFixedHeight(270)
        root.addWidget(self.preview)

        pill = QFrame()
        pill.setObjectName("Pill")
        pl = QHBoxLayout(pill)
        pl.setContentsMargins(16, 10, 16, 10)
        self.dot = QLabel("●")
        self.status = QLabel("Starting...")
        self.status.setStyleSheet("font-size: 13px; font-weight: 600;")
        pl.addWidget(self.dot)
        pl.addWidget(self.status, 1)
        root.addWidget(pill)

        self.stats = QLabel("")
        self.stats.setObjectName("Stats")
        self.stats.setAlignment(Qt.AlignCenter)
        root.addWidget(self.stats)

        self.res = QComboBox()
        for label, _ in RESOLUTIONS:
            self.res.addItem(label)
        self.res.currentIndexChanged.connect(self.on_res)
        root.addWidget(self.res)
        root.addStretch(1)
        self.setCentralWidget(central)

        self.set_status("Starting...", "wait")
        self.worker = StreamWorker()
        self.worker.status.connect(self.set_status)
        self.worker.stats.connect(self.stats.setText)
        self.worker.preview.connect(self.set_preview)
        self.worker.start()

    def on_res(self, i):
        self.worker.target = RESOLUTIONS[i][1]

    def set_status(self, text, state):
        self.status.setText(text)
        self.dot.setStyleSheet("color: %s; font-size: 14px;" % self.COLORS.get(state, "#888"))
        if state != "live":
            self.preview.setPixmap(QPixmap())
            self.preview.setText("No video yet")

    def set_preview(self, img):
        pm = QPixmap.fromImage(img).scaled(self.preview.width() - 4, self.preview.height() - 4,
                                           Qt.KeepAspectRatio, Qt.FastTransformation)
        self.preview.setPixmap(pm)

    def closeEvent(self, event):
        self.worker.stop()
        self.worker.wait(2000)
        event.accept()


if __name__ == "__main__":
    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    w = MainWindow()
    w.show()
    sys.exit(app.exec_())
