# distutils: language = c++
import threading

import numpy

from libc.stdint cimport intptr_t, uint64_t, uint32_t

import cupy
from cupy.cuda cimport stream
from cupy._core.core cimport ndarray
from cupy.random._generator_api import init_curand, random_raw

# We need access to the sizes here, so this is why we have this header
# in here instead of cupy backends
cdef extern from 'cupy_distributions.cuh' nogil:
    cppclass curandState:
        pass
    cppclass curandStateMRG32k3a:
        pass
    cppclass curandStatePhilox4_32_10_t:
        pass

    cdef enum _RandGenerators 'RandGenerators':
        CURAND_XOR_WOW
        CURAND_MRG32k3a
        CURAND_PHILOX_4x32_10


class BitGenerator:
    """Generic BitGenerator.

    Base Class for generic BitGenerators, which provide a stream
    of random bits based on different algorithms. Must be overridden.

    Args:
        seed (int, array_like[ints], numpy.random.SeedSequence, optional):
            A seed to initialize the `BitGenerator`. If None, then fresh,
            unpredictable entropy will be pulled from the OS. If an ``int`` or
            ``array_like[ints]`` is passed, then it will be passed to
            ~`numpy.random.SeedSequence` to derive the initial `BitGenerator`
            state. One may also pass in a `SeedSequence` instance.
    """
    def __init__(self, seed=None):
        self.lock = threading.Lock()
        # TODO(ecastill) port SeedSequence
        if isinstance(seed, numpy.random.SeedSequence):
            self._seed_seq = seed
        else:
            if isinstance(seed, cupy.ndarray):
                seed = cupy.asnumpy(seed)
            self._seed_seq = numpy.random.SeedSequence(seed)
        self._current_device_id = cupy.cuda.get_device_id()

    def random_raw(self, size=None, output=True):
        raise NotImplementedError(
            'Not implemented in base BitGenerator')

    def _state_size(self):
        """Maximum number of samples that can be generated at once
        """
        return 0

    def _check_device(self):
        if cupy.cuda.get_device_id() != self._current_device_id:
            raise RuntimeError(
                'This Generator state is allocated in a different device')


class _cuRANDGenerator(BitGenerator):
    # Size is the number of threads that will be initialized
    def __init__(self, seed=None, *, size=1000*256):
        super().__init__(seed)
        # Raw kernel has problems with integers with the 64th bit set
        self._seed = self._seed_seq.generate_state(1, numpy.uint32)[0]
        self._size = size
        cdef uint64_t b_size = self._type_size() * size
        self._state = cupy.zeros(b_size, dtype=numpy.int8)
        self._basic = cupy.zeros(b_size, dtype=numpy.int8)
        ptr = self._state.data.ptr
        ptr_basic = self._basic.data.ptr
        # Initialize the state
        init_curand(self.generator, ptr, self._seed, size)

    def random_raw(self, size=None, output=True):
        """Return randoms as generated by the underlying BitGenerator.

        Args:
            size (int or tuple of ints, optional):
                Output shape.  If the given shape is, e.g., ``(m, n, k)``, then
                ``m * n * k`` samples are drawn.  Default is None, in which
                case a single value is returned.
            output (bool, optional):
                Output values.  Used for performance testing since the
                generated values are not returned.

        Returns:
            cupy.ndarray: Drawn samples.

        .. note::
            This method directly exposes the the raw underlying pseudo-random
            number generator. All values are returned as unsigned 64-bit
            values irrespective of the number of bits produced by the PRNG.
            See the class docstring for the number of bits returned.

        """
        shape = size if size is not None else ()
        y = cupy.zeros(shape, dtype=numpy.int32)
        random_raw(self, y)
        return y if output else None

    def state(self):
        self._check_device()
        return self._state.data.ptr

    def basic(self):
        self._check_device()
        return self._basic.data.ptr

    def _state_size(self):
        return self._size

    def _type_size(self):
        return 0


class XORWOW(_cuRANDGenerator):
    """BitGenerator that uses cuRAND XORWOW device generator.

    This generator allocates the state using the cuRAND device API.

    Args:
        seed (None, int, array_like[ints], numpy.random.SeedSequence):
            A seed to initialize the `BitGenerator`. If None, then fresh,
            unpredictable entropy will be pulled from the OS. If an ``int`` or
            ``array_like[ints]`` is passed, then it will be passed to
            ~`numpy.random.SeedSequence` to derive the initial `BitGenerator`
            state. One may also pass in a `SeedSequence` instance.
        size (int): Maximum number of samples that can be generated at once.
            defaults to 1000 * 256.
    """
    generator = CURAND_XOR_WOW  # Use The Enum

    def _type_size(self):
        return sizeof(curandState)


class MRG32k3a(_cuRANDGenerator):
    """BitGenerator that uses cuRAND MRG32k3a device generator.

    This generator allocates the state using the cuRAND device API.

    Args:
        seed (int, array_like[ints], numpy.random.SeedSequence, optional):
            A seed to initialize the `BitGenerator`. If None, then fresh,
            unpredictable entropy will be pulled from the OS. If an ``int`` or
            ``array_like[ints]`` is passed, then it will be passed to
            ~`numpy.random.SeedSequence` to derive the initial `BitGenerator`
            state. One may also pass in a `SeedSequence` instance.
        size (int): Maximum number of samples that can be generated at once.
            defaults to 1000 * 256.
    """
    generator = CURAND_MRG32k3a

    def _type_size(self):
        return sizeof(curandStateMRG32k3a)


class Philox4x3210(_cuRANDGenerator):
    """BitGenerator that uses cuRAND Philox4x3210 device generator.

    This generator allocates the state using the cuRAND device API.

    Args:
        seed (int, array_like[ints], numpy.random.SeedSequence, optional):
            A seed to initialize the `BitGenerator`. If None, then fresh,
            unpredictable entropy will be pulled from the OS. If an ``int`` or
            ``array_like[ints]`` is passed, then it will be passed to
            ~`numpy.random.SeedSequence` to derive the initial `BitGenerator`
            state. One may also pass in a `SeedSequence` instance.
        size (int): Maximum number of samples that can be generated at once.
            defaults to 1000 * 256.
    """
    generator = CURAND_PHILOX_4x32_10

    def _type_size(self):
        return sizeof(curandStatePhilox4_32_10_t)
