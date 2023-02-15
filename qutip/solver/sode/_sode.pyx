#cython: language_level=3

from qutip.core import data as _data
from qutip.core.cy.qobjevo cimport QobjEvo
from qutip.core.data cimport Data, Dense
from collections import defaultdict
cimport cython
from qutip.solver.sode.ssystem cimport _StochasticSystem
import numpy as np


cdef class Euler:
    cdef _StochasticSystem system

    def __init__(self, _StochasticSystem system):
        self.system = system

    @cython.wraparound(False)
    def run(
        self, double t, Data state, double dt,
        double[:, :, ::1] dW, int ntraj
    ):
        cdef int i
        cdef Dense out
        for i in range(ntraj):
            out = self.step(t, state, dt, dW[i, :, :])
            state = out
        return out

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef step(self, double t, Data state, double dt, double[:, :] dW):
        """
        Integration scheme:
        Basic Euler order 0.5
        dV = d1 dt + d2_i dW_i
        Numerical Solution of Stochastic Differential Equations
        By Peter E. Kloeden, Eckhard Platen
        """
        cdef int i
        cdef _StochasticSystem system = self.system

        a = system.drift(t, state)
        b = system.diffusion(t, state)
        new_state = _data.add(state, a, dt)
        for i in range(system.num_collapse):
            new_state = _data.add(new_state, b[i], dW[i, 0])
        return new_state


cdef class Platen(Euler):
    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef step(self, double t, Data state, double dt, double[:, :] dW):
        """
        Platen rhs function for both master eq and schrodinger eq.
        dV = -iH* (V+Vt)/2 * dt + (d1(V)+d1(Vt))/2 * dt
             + (2*d2_i(V)+d2_i(V+)+d2_i(V-))/4 * dW_i
             + (d2_i(V+)-d2_i(V-))/4 * (dW_i**2 -dt) * dt**(-.5)

        Vt = V -iH*V*dt + d1*dt + d2_i*dW_i
        V+/- = V -iH*V*dt + d1*dt +/- d2_i*dt**.5
        The Theory of Open Quantum Systems
        Chapter 7 Eq. (7.47), H.-P Breuer, F. Petruccione
        """
        cdef _StochasticSystem system = self.system
        cdef int i, j, num_ops = system.num_collapse
        cdef double sqrt_dt = np.sqrt(dt)
        cdef double sqrt_dt_inv = 0.25 / sqrt_dt
        cdef double dw, dw2

        cdef Data d1 = _data.add(state, system.drift(t, state), dt)
        cdef list d2 = system.diffusion(t, state)
        cdef Data Vt, out
        cdef list Vp, Vm

        out = _data.mul(d1, 0.5)
        Vt = d1.copy()
        Vp = []
        Vm = []
        for i in range(num_ops):
            Vp.append(_data.add(d1, d2[i], sqrt_dt))
            Vm.append(_data.add(d1, d2[i], -sqrt_dt))
            Vt = _data.add(Vt, d2[i], dW[i, 0])

        d1 = system.drift(t, Vt)
        out = _data.add(out, d1, 0.5 * dt)
        out = _data.add(out, state, 0.5)
        for i in range(num_ops):
            d2p = system.diffusion(t, Vp[i])
            d2m = system.diffusion(t, Vm[i])
            dw = dW[i, 0] * 0.25
            out = _data.add(out, d2m[i], dw)
            out = _data.add(out, d2[i], 2 * dw)
            out = _data.add(out, d2p[i], dw)

            for j in range(num_ops):
                dw2 = sqrt_dt_inv * (dW[i, 0] * dW[j, 0] - dt * (i == j))
                out = _data.add(out, d2p[j], dw2)
                out = _data.add(out, d2m[j], -dw2)

        return out


cdef class Explicit15(Euler):
    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef step(self, double t, Data state, double dt, double[:, :] dW):
        """
        Chapter 11.2 Eq. (2.13)
        Numerical Solution of Stochastic Differential Equations
        By Peter E. Kloeden, Eckhard Platen
        """
        cdef _StochasticSystem system = self.system
        cdef int i, j, k, num_ops = system.num_collapse
        cdef double sqrt_dt = np.sqrt(dt)
        cdef double sqrt_dt_inv = 1./sqrt_dt
        cdef double ddz, ddw, ddd
        cdef double[::1] dz, dw

        dw = np.empty(num_ops)
        dz = np.empty(num_ops)
        for i in range(num_ops):
            dw[i] = dW[i, 0]
            dz[i] = 0.5 *(dW[i, 0] + 1./np.sqrt(3) * dW[i, 1])

        d1 = system.drift(t, state)
        d2 = system.diffusion(t, state)
        dd2 = system.diffusion(t + dt, state)
        # Euler part
        out = _data.add(state, d1, dt)
        for i in range(num_ops):
            out = _data.add(out, d2[i], dw[i])

        V = _data.add(state, d1, dt/num_ops)

        v2p = []
        v2m = []
        for i in range(num_ops):
            v2p.append(_data.add(V, d2[i], sqrt_dt))
            v2m.append(_data.add(V, d2[i], -sqrt_dt))

        p2p = []
        p2m = []
        for i in range(num_ops):
            d2p = system.diffusion(t, v2p[i])
            d2m = system.diffusion(t, v2m[i])
            ddw = (dw[i] * dw[i] - dt) * 0.25 * sqrt_dt_inv  # 1.0
            out = _data.add(out, d2p[i], ddw)
            out = _data.add(out, d2m[i], -ddw)
            temp_p2p = []
            temp_p2m = []
            for j in range(num_ops):
                temp_p2p.append(_data.add(v2p[i], d2p[j], sqrt_dt))
                temp_p2m.append(_data.add(v2p[i], d2p[j], -sqrt_dt))
            p2p.append(temp_p2p)
            p2m.append(temp_p2m)

        out = _data.add(out, d1, -0.5*(num_ops) * dt)

        for i in range(num_ops):
            ddz = dz[i] * 0.5 / sqrt_dt # 1.5
            ddd = 0.25 * (dw[i] * dw[i] / 3 - dt) * dw[i] / dt # 1.5

            d1p = system.drift(t + dt/num_ops, v2p[i])
            d1m = system.drift(t + dt/num_ops, v2m[i])

            d2p = system.diffusion(t, v2p[i])
            d2m = system.diffusion(t, v2m[i])
            d2pp = system.diffusion(t, p2p[i][i])
            d2mm = system.diffusion(t, p2m[i][i])

            out = _data.add(out, d1p, (0.25 + ddz) * dt)
            out = _data.add(out, d1m, (0.25 - ddz) * dt)

            out = _data.add(out, dd2[i], dw[i] - dz[i])
            out = _data.add(out, d2[i], dz[i] - dw[i])

            out = _data.add(out, d2pp[i], ddd)
            out = _data.add(out, d2mm[i], -ddd)
            out = _data.add(out, d2p[i], -ddd)
            out = _data.add(out, d2m[i], ddd)

            for j in range(num_ops):
                ddw = 0.5 * (dw[j] - dz[j])  # O(1.5)
                out = _data.add(out, d2p[j], ddw)
                out = _data.add(out, d2[j], -2*ddw)
                out = _data.add(out, d2m[j], ddw)

                if j > i:
                    ddw = 0.5 * (dw[i] * dw[j]) / sqrt_dt  # O(1.0)
                    out = _data.add(out, d2p[j], ddw)
                    out = _data.add(out, d2m[j], -ddw)

                    ddw = 0.25 * (dw[j] * dw[j] - dt) * dw[i] / dt  # O(1.5)
                    d2pp = system.diffusion(t, p2p[j][i])
                    d2mm = system.diffusion(t, p2m[j][i])

                    out = _data.add(out, d2pp[j], ddw)
                    out = _data.add(out, d2mm[j], -ddw)
                    out = _data.add(out, d2p[j], -ddw)
                    out = _data.add(out, d2m[j], ddw)

                    for k in range(j+1, num_ops):
                        ddw = 0.5 * dw[i] * dw[j] * dw[k] / dt  # O(1.5)

                        out = _data.add(out, d2pp[k], ddw)
                        out = _data.add(out, d2mm[k], -ddw)
                        out = _data.add(out, d2p[k], -ddw)
                        out = _data.add(out, d2m[k], ddw)

                if j < i:
                    ddw = 0.25 * (dw[j] * dw[j] - dt) * dw[i] / dt  # O(1.5)

                    d2pp = system.diffusion(t, p2p[j][i])
                    d2mm = system.diffusion(t, p2m[j][i])

                    out = _data.add(out, d2pp[j], ddw)
                    out = _data.add(out, d2mm[j], -ddw)
                    out = _data.add(out, d2p[j], -ddw)
                    out = _data.add(out, d2m[j], ddw)

        return out


cdef class Milstein:
    cdef _StochasticSystem system

    def __init__(self, _StochasticSystem system):
        self.system = system

    @cython.wraparound(False)
    def run(self, double t, Data state, double dt, double[:, :, ::1] dW, int ntraj):
        cdef int i
        if type(state) != _data.Dense:
            state = _data.to(_data.Dense, state)
        cdef Dense out = _data.mul_dense(state, 0)
        state = state.copy()

        for i in range(ntraj):
            self.step(t, state, dt, dW[i, :, :], out)
            state, out = out, state
        return state

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef step(self, double t, Dense state, double dt, double[:, :] dW, Dense out):
        """
        Chapter 10.3 Eq. (3.1)
        Numerical Solution of Stochastic Differential Equations
        By Peter E. Kloeden, Eckhard Platen

        dV = -iH*V*dt + d1*dt + d2_i*dW_i
        + 0.5*d2_i' d2_j*(dW_i*dw_j -dt*delta_ij)
        """
        cdef _StochasticSystem system = self.system
        cdef int i, j, num_ops = system.num_collapse
        cdef double dw

        system.set_state(t, state)

        _data.imul_dense(out, 0.)
        _data.iadd_dense(out, state, 1)
        _data.iadd_dense(out, system.a(), dt)

        for i in range(num_ops):
            _data.iadd_dense(out, system.bi(i), dW[i, 0])

        for i in range(num_ops):
            for j in range(i, num_ops):
                if i == j:
                    dw = (dW[i, 0] * dW[j, 0] - dt) * 0.5
                else:
                    dw = dW[i, 0] * dW[j, 0]
                _data.iadd_dense(out, system.Libj(i, j), dw)


cdef class PredCorr:
    cdef Dense euler
    cdef double alpha, eta
    cdef _StochasticSystem system

    def __init__(self, _StochasticSystem system, double alpha=0., double eta=0.5):
        self.system = system
        self.alpha = alpha
        self.eta = eta

    @cython.wraparound(False)
    def run(self, double t, Data state, double dt, double[:, :, ::1] dW, int ntraj):
        cdef int i
        if type(state) != _data.Dense:
            state = _data.to(_data.Dense, state)
        cdef Dense out = _data.mul_dense(state, 0)
        self.euler = _data.mul_dense(state, 0)
        state = state.copy()

        for i in range(ntraj):
            self.step(t, state, dt, dW[i, :, :], out)
            state, out = out, state
        return state

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef step(self, double t, Dense state, double dt, double[:, :] dW, Dense out):
        """
        Chapter 10.3 Eq. (3.1)
        Numerical Solution of Stochastic Differential Equations
        By Peter E. Kloeden, Eckhard Platen

        dV = -iH*V*dt + d1*dt + d2_i*dW_i
        + 0.5*d2_i' d2_j*(dW_i*dw_j -dt*delta_ij)
        """
        cdef _StochasticSystem system = self.system
        cdef int i, j, k, num_ops = system.num_collapse
        cdef double eta=self.eta, alpha=self.alpha
        cdef Dense euler = self.euler

        system.set_state(t, state)

        _data.imul_dense(out, 0.)
        _data.iadd_dense(out, state, 1)
        _data.iadd_dense(out, system.a(), dt*(1-alpha))

        _data.imul_dense(euler, 0.)
        _data.iadd_dense(euler, state, 1)
        _data.iadd_dense(euler, system.a(), dt)

        for i in range(num_ops):
            _data.iadd_dense(euler, system.bi(i), dW[i, 0])
            _data.iadd_dense(out, system.bi(i), dW[i, 0]*eta)
            _data.iadd_dense(out, system.Libj(i, i), dt*(alpha-1)*0.5)

        system.set_state(t+dt, euler)
        if alpha:
            _data.iadd_dense(out, system.a(), dt*alpha)

        for i in range(num_ops):
            _data.iadd_dense(out, system.bi(i), dW[i, 0]*(1-eta))
            _data.iadd_dense(out, system.Libj(i, i), -dt*alpha*0.5)

        return out


cdef class Taylor15(Milstein):
    @cython.wraparound(False)
    def run(self, double t, Data state, double dt, double[:, :, ::1] dW, int ntraj):
        cdef int i
        if type(state) != _data.Dense:
            state = _data.to(_data.Dense, state)
        cdef Dense out = _data.mul_dense(state, 0)
        state = state.copy()

        for i in range(ntraj):
            self.step(t, state, dt, dW[i, :, :], out)
            state, out = out, state
        return state

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef step(self, double t, Dense state, double dt, double[:, :] dW, Dense out):
        """
        Chapter 12.2 Eq. (2.18),
        Numerical Solution of Stochastic Differential Equations
        By Peter E. Kloeden, Eckhard Platen
        """
        cdef _StochasticSystem system = self.system
        system.set_state(t, state)
        cdef int i, j, k, num_ops = system.num_collapse
        cdef double[:] dz, dw

        num_ops = system.num_collapse
        dw = dW[:, 0]
        dz = 0.5 *(dW[:, 0] + 1./np.sqrt(3) * dW[:, 1]) * dt

        _data.imul_dense(out, 0.)
        _data.iadd_dense(out, state, 1)
        _data.iadd_dense(out, system.a(), dt)
        _data.iadd_dense(out, system.L0a(), 0.5 * dt * dt)

        for i in range(num_ops):
            _data.iadd_dense(out, system.bi(i), dw[i])
            _data.iadd_dense(out, system.Libj(i, i), 0.5 * (dw[i] * dw[i] - dt))
            _data.iadd_dense(out, system.Lia(i), dz[i])
            _data.iadd_dense(out, system.L0bi(i), dw[i] * dt - dz[i])
            _data.iadd_dense(out, system.LiLjbk(i, i, i),
                             0.5 * ((1/3.) * dw[i] * dw[i] - dt) * dw[i])

            for j in range(i+1, num_ops):
                _data.iadd_dense(out, system.Libj(i, j), dw[i] * dw[j])
                _data.iadd_dense(out, system.LiLjbk(i, j, j), 0.5 * (dw[j] * dw[j] -dt) * dw[i])
                _data.iadd_dense(out, system.LiLjbk(i, i, j), 0.5 * (dw[i] * dw[i] -dt) * dw[j])
                for k in range(j+1, num_ops):
                    _data.iadd_dense(out, system.LiLjbk(i, j, k), dw[i]*dw[j]*dw[k])

        return out
