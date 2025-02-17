import numpy as np
import time
from openpilot.common.realtime import DT_MDL
from openpilot.common.numpy_fast import interp
from openpilot.system.swaglog import cloudlog
from openpilot.selfdrive.controls.lib.legacy_lateral_mpc_lib.lat_mpc import LateralMpc
from openpilot.selfdrive.controls.lib.drive_helpers import CONTROL_N, MPC_COST_LAT, LAT_MPC_N, CAR_ROTATION_RADIUS
from openpilot.selfdrive.controls.lib.lane_planner import LanePlanner, TRAJECTORY_SIZE
from openpilot.selfdrive.controls.lib.desire_helper import DesireHelper
import cereal.messaging as messaging
from cereal import log
from openpilot.common.params import Params

STEER_RATE_COST = {
  "chrysler": 0.7,
  "ford": 1.,
  "gm": 1.,
  "honda": 0.5,
  "hyundai": 0.5,
  "mazda": 1.,
  "nissan": 0.5,
  "subaru": 0.7,
  "tesla": 0.5,
  "toyota": 1.,
  "volkswagen": 1.,
}

class LateralPlanner:
  def __init__(self, CP, debug=False):
    self.LP = LanePlanner()
    self.DH = DesireHelper()
    self._dp_lat_lane_priority_mode = Params().get_bool("dp_lat_lane_priority_mode")
    self._dp_lat_lane_priority_mode_active = False
    self._dp_lat_lane_priority_mode_active_prev = False

    self.last_cloudlog_t = 0
    try:
      self.steer_rate_cost = STEER_RATE_COST[CP.carName]
    except:
      self.steer_rate_cost = 0.
    self.solution_invalid_cnt = 0

    self.path_xyz = np.zeros((TRAJECTORY_SIZE, 3))
    self.path_xyz_stds = np.ones((TRAJECTORY_SIZE, 3))
    self.plan_yaw = np.zeros((TRAJECTORY_SIZE,))
    self.t_idxs = np.arange(TRAJECTORY_SIZE)
    self.y_pts = np.zeros(TRAJECTORY_SIZE)
    # dp // mapd - for vision turn controller
    self._d_path_w_lines_xyz = np.zeros((TRAJECTORY_SIZE, 3))

    self.lat_mpc = LateralMpc()
    self.reset_mpc(np.zeros(4))

  def reset_mpc(self, x0=np.zeros(4)):
    self.x0 = x0
    self.lat_mpc.reset(x0=self.x0)

  def update(self, sm):
    v_ego = sm['carState'].vEgo
    measured_curvature = sm['controlsState'].curvature

    # Parse model predictions
    md = sm['modelV2']
    self.LP.parse_model(md)
    if len(md.position.x) == TRAJECTORY_SIZE and len(md.orientation.x) == TRAJECTORY_SIZE:
      self.path_xyz = np.column_stack([md.position.x, md.position.y, md.position.z])
      self.t_idxs = np.array(md.position.t)
      self.plan_yaw = list(md.orientation.z)
    if len(md.position.xStd) == TRAJECTORY_SIZE:
      self.path_xyz_stds = np.column_stack([md.position.xStd, md.position.yStd, md.position.zStd])

    # Lane change logic
    lane_change_prob = self.LP.l_lane_change_prob + self.LP.r_lane_change_prob
    self.DH.update(sm['carState'], sm['carControl'].latActive, lane_change_prob)

    # Turn off lanes during lane change
    if self.DH.desire == log.LateralPlan.Desire.laneChangeRight or self.DH.desire == log.LateralPlan.Desire.laneChangeLeft:
      self.LP.lll_prob *= self.DH.lane_change_ll_prob
      self.LP.rll_prob *= self.DH.lane_change_ll_prob

    use_laneline = False
    # dp - check laneline prob when priority is on
    if self._dp_lat_lane_priority_mode:
      self._update_laneless_laneline_mode()
      use_laneline = self._dp_lat_lane_priority_mode_active

    # Calculate final driving path and set MPC costs
    if use_laneline:
      d_path_xyz = self.LP.get_d_path(v_ego, self.t_idxs, self.path_xyz)
      self.lat_mpc.set_weights(MPC_COST_LAT.PATH, MPC_COST_LAT.HEADING, self.steer_rate_cost)
    else:
      d_path_xyz = self.path_xyz
      path_cost = np.clip(abs(self.path_xyz[0, 1] / self.path_xyz_stds[0, 1]), 0.5, 1.5) * MPC_COST_LAT.PATH
      # Heading cost is useful at low speed, otherwise end of plan can be off-heading
      heading_cost = interp(v_ego, [5.0, 10.0], [MPC_COST_LAT.HEADING, 0.0])
      self.lat_mpc.set_weights(path_cost, heading_cost, self.steer_rate_cost)

    self._d_path_w_lines_xyz = d_path_xyz

    y_pts = np.interp(v_ego * self.t_idxs[:LAT_MPC_N + 1], np.linalg.norm(d_path_xyz, axis=1), d_path_xyz[:, 1])
    heading_pts = np.interp(v_ego * self.t_idxs[:LAT_MPC_N + 1], np.linalg.norm(self.path_xyz, axis=1), self.plan_yaw)
    self.y_pts = y_pts

    assert len(y_pts) == LAT_MPC_N + 1
    assert len(heading_pts) == LAT_MPC_N + 1
    # self.x0[4] = v_ego
    p = np.array([v_ego, CAR_ROTATION_RADIUS])
    self.lat_mpc.run(self.x0,
                     p,
                     y_pts,
                     heading_pts)
    # init state for next
    self.x0[3] = interp(DT_MDL, self.t_idxs[:LAT_MPC_N + 1], self.lat_mpc.x_sol[:, 3])

    #  Check for infeasible MPC solution
    mpc_nans = np.isnan(self.lat_mpc.x_sol[:, 3]).any()
    t = time.monotonic()
    if mpc_nans or self.lat_mpc.solution_status != 0:
      self.reset_mpc()
      self.x0[3] = measured_curvature
      if t > self.last_cloudlog_t + 5.0:
        self.last_cloudlog_t = t
        cloudlog.warning("Lateral mpc - nan: True")

    if self.lat_mpc.cost > 20000. or mpc_nans:
      self.solution_invalid_cnt += 1
    else:
      self.solution_invalid_cnt = 0

  def publish(self, sm, pm):
    plan_solution_valid = self.solution_invalid_cnt < 2
    plan_send = messaging.new_message('lateralPlan')
    plan_send.valid = sm.all_checks(service_list=['carState', 'controlsState', 'modelV2'])

    lateralPlan = plan_send.lateralPlan
    # lateralPlan.laneWidth = float(self.LP.lane_width)
    lateralPlan.dPathPoints = self.y_pts.tolist()
    lateralPlan.psis = self.lat_mpc.x_sol[0:CONTROL_N, 2].tolist()
    lateralPlan.curvatures = self.lat_mpc.x_sol[0:CONTROL_N, 3].tolist()
    lateralPlan.curvatureRates = [float(x) for x in self.lat_mpc.u_sol[0:CONTROL_N - 1]] + [0.0]
    # lateralPlan.lProb = float(self.LP.lll_prob)
    # lateralPlan.rProb = float(self.LP.rll_prob)
    # lateralPlan.dProb = float(self.LP.d_prob)

    lateralPlan.mpcSolutionValid = bool(plan_solution_valid)
    lateralPlan.solverExecutionTime = self.lat_mpc.solve_time

    lateralPlan.desire = self.DH.desire
    lateralPlan.useLaneLines = self._dp_lat_lane_priority_mode and self._dp_lat_lane_priority_mode_active
    lateralPlan.laneChangeState = self.DH.lane_change_state
    lateralPlan.laneChangeDirection = self.DH.lane_change_direction

    pm.send('lateralPlan', plan_send)

    # dp - extension
    plan_ext_send = messaging.new_message('lateralPlanExt')

    lateralPlanExt = plan_ext_send.lateralPlanExt
    # for vision turn controller
    lateralPlanExt.dPathWLinesX = [float(x) for x in self._d_path_w_lines_xyz[:, 0]]
    lateralPlanExt.dPathWLinesY = [float(y) for y in self._d_path_w_lines_xyz[:, 1]]

    pm.send('lateralPlanExt', plan_ext_send)

  def _update_laneless_laneline_mode(self):
    # decide what mode should we use
    if (self.LP.lll_prob + self.LP.rll_prob)/2 < 0.3:
      self._dp_lat_lane_priority_mode_active = False
    if (self.LP.lll_prob + self.LP.rll_prob)/2 > 0.5:
      self._dp_lat_lane_priority_mode_active = True

    # perform reset mpc
    if self._dp_lat_lane_priority_mode_active != self._dp_lat_lane_priority_mode_active_prev:
      self.reset_mpc()
    self._dp_lat_lane_priority_mode_active_prev = self._dp_lat_lane_priority_mode_active
