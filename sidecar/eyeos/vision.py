"""MediaPipe wrappers (SPEC §3). Produces the per-frame dict metrics.Engine consumes."""
from pathlib import Path

import cv2
import mediapipe as mp
from mediapipe.tasks.python import BaseOptions
from mediapipe.tasks.python import vision as mpv

MODELS = Path(__file__).resolve().parent.parent / "models"


class Vision:
    # shortcut: VIDEO mode (synchronous) instead of LIVE_STREAM; same output, frames drop at the camera instead of in MediaPipe.
    def __init__(self, hands_every=3, luma_every=10, pose_every=3):
        self.face = mpv.FaceLandmarker.create_from_options(mpv.FaceLandmarkerOptions(
            base_options=BaseOptions(model_asset_path=str(MODELS / "face_landmarker.task")),
            running_mode=mpv.RunningMode.VIDEO, num_faces=1,
            output_face_blendshapes=True, output_facial_transformation_matrixes=True,
            min_face_detection_confidence=0.5, min_tracking_confidence=0.5))
        self.hands = mpv.HandLandmarker.create_from_options(mpv.HandLandmarkerOptions(
            base_options=BaseOptions(model_asset_path=str(MODELS / "hand_landmarker.task")),
            running_mode=mpv.RunningMode.VIDEO, num_hands=2))
        # shoulders + ears for posture (the face alone can't tell slumping from leaning in)
        self.pose = mpv.PoseLandmarker.create_from_options(mpv.PoseLandmarkerOptions(
            base_options=BaseOptions(model_asset_path=str(MODELS / "pose_landmarker.task")),
            running_mode=mpv.RunningMode.VIDEO, num_poses=1)) if (MODELS / "pose_landmarker.task").exists() else None
        self.hands_every, self.luma_every, self.pose_every = hands_every, luma_every, pose_every
        self.n = 0
        self.last_ms = -1

    def process(self, bgr, ts):
        """bgr: unmirrored camera frame. ts: unix seconds. Returns a frame dict."""
        h, w = bgr.shape[:2]
        ms = max(int(ts * 1000), self.last_ms + 1)  # MediaPipe needs strictly increasing timestamps
        self.last_ms = ms
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        img = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
        res = self.face.detect_for_video(img, ms)
        f = {"ts": ts, "w": w, "h": h, "face": None, "blend": {}, "transform": None, "hands": None, "luma": None, "pose": None}
        if res.face_landmarks:
            f["face"] = [[p.x, p.y, p.z] for p in res.face_landmarks[0]]
            if res.face_blendshapes:
                f["blend"] = {c.category_name: round(c.score, 4) for c in res.face_blendshapes[0]}
            if res.facial_transformation_matrixes:
                f["transform"] = [round(float(v), 5) for v in res.facial_transformation_matrixes[0].flatten()]
        if self.n % self.hands_every == 0:
            hr = self.hands.detect_for_video(img, ms)
            f["hands"] = [[[p.x, p.y, p.z] for p in hand] for hand in hr.hand_landmarks]
        if self.pose and self.n % self.pose_every == 1:
            pr = self.pose.detect_for_video(img, ms)
            # upper body only (0 nose .. 12 right shoulder): x, y, z, visibility; plus the same points in metres (world
            # coordinates, y down, z toward the camera negative), which show how far the head sits in front of the shoulders
            f["pose"] = [[p.x, p.y, p.z, p.visibility] for p in pr.pose_landmarks[0][:13]] if pr.pose_landmarks else []
            f["pose_world"] = [[p.x, p.y, p.z] for p in pr.pose_world_landmarks[0][:13]] if pr.pose_world_landmarks else None
        if self.n % self.luma_every == 0:
            f["luma"] = float(cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY).mean())
        self.n += 1
        return f

    def close(self):
        self.face.close()
        self.hands.close()
        if self.pose:
            self.pose.close()
