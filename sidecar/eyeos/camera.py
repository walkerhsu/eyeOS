"""Webcam capture. Python is the only process that opens the camera (SPEC §2).

Captures with AVFoundation directly (not OpenCV) so we can pick the Mac's built-in camera by device
type; OpenCV only takes an index, which can land on a Continuity Camera iPhone.
"""
import sys
import threading
import time

import AVFoundation as AV
import CoreMedia
import cv2
import numpy as np
import objc
import Quartz
from dispatch import dispatch_queue_create
from Foundation import NSObject

WIDTH = 640


def builtin_device():
    devices = AV.AVCaptureDeviceDiscoverySession.discoverySessionWithDeviceTypes_mediaType_position_(
        [AV.AVCaptureDeviceTypeBuiltInWideAngleCamera], AV.AVMediaTypeVideo, AV.AVCaptureDevicePositionUnspecified).devices()
    return devices[0] if devices else None


class _Delegate(NSObject):
    def initWithCamera_(self, cam):
        self = objc.super(_Delegate, self).init()
        self.cam = cam
        return self

    def captureOutput_didOutputSampleBuffer_fromConnection_(self, output, sample, conn):
        pb = CoreMedia.CMSampleBufferGetImageBuffer(sample)
        Quartz.CVPixelBufferLockBaseAddress(pb, Quartz.kCVPixelBufferLock_ReadOnly)
        try:
            h, w = Quartz.CVPixelBufferGetHeight(pb), Quartz.CVPixelBufferGetWidth(pb)
            row = Quartz.CVPixelBufferGetBytesPerRow(pb)
            buf = Quartz.CVPixelBufferGetBaseAddress(pb).as_buffer(row * h)
            bgra = np.frombuffer(buf, np.uint8).reshape(h, row // 4, 4)[:, :w]
            frame = np.ascontiguousarray(bgra[:, :, :3])  # copy out before the buffer is unlocked
        finally:
            Quartz.CVPixelBufferUnlockBaseAddress(pb, Quartz.kCVPixelBufferLock_ReadOnly)
        self.cam._push(time.time(), frame)


class Camera:
    def __init__(self):
        self.cap = None  # the running AVCaptureSession; None when released
        self._cond = threading.Condition()
        self._latest = None

    def open(self):
        dev = builtin_device()
        if dev is None:
            print("eyeos: no built-in camera found", file=sys.stderr, flush=True)
            return False
        inp, err = AV.AVCaptureDeviceInput.deviceInputWithDevice_error_(dev, None)
        if inp is None:
            print(f"eyeos: camera unavailable: {err}", file=sys.stderr, flush=True)
            return False
        session = AV.AVCaptureSession.alloc().init()
        if session.canSetSessionPreset_(AV.AVCaptureSessionPreset640x480):
            session.setSessionPreset_(AV.AVCaptureSessionPreset640x480)
        out = AV.AVCaptureVideoDataOutput.alloc().init()
        out.setVideoSettings_({Quartz.kCVPixelBufferPixelFormatTypeKey: Quartz.kCVPixelFormatType_32BGRA})
        out.setAlwaysDiscardsLateVideoFrames_(True)
        self._delegate = _Delegate.alloc().initWithCamera_(self)
        out.setSampleBufferDelegate_queue_(self._delegate, dispatch_queue_create(b"eyeos.camera", None))
        if not (session.canAddInput_(inp) and session.canAddOutput_(out)):
            return False
        session.addInput_(inp)
        session.addOutput_(out)
        session.startRunning()
        self.cap = session
        print(f"eyeos: camera = {dev.localizedName()}", file=sys.stderr, flush=True)
        return True

    def _push(self, ts, frame):
        with self._cond:
            self._latest = (ts, frame)
            self._cond.notify()

    def read(self):
        """Blocks for the next frame. Returns (ts, bgr) or (None, None) after 2 s without one."""
        if self.cap is None:
            return None, None
        with self._cond:
            if self._latest is None and not self._cond.wait(2):
                return None, None
            ts, frame = self._latest
            self._latest = None
        h, w = frame.shape[:2]
        if w != WIDTH:  # the built-in camera ignores the 640x480 preset and delivers 1080p
            frame = cv2.resize(frame, (WIDTH, round(h * WIDTH / w)), interpolation=cv2.INTER_AREA)
        return ts, frame

    def release(self):
        if self.cap is not None:
            self.cap.stopRunning()
            self.cap = None
