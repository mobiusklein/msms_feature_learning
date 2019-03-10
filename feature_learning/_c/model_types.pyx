# cython: embedsignature=True
# distutils: include_dirs = C:\Users\Asus\Miniconda2\lib\site-packages\numpy\core\include
cimport cython
from cpython cimport PyTuple_GetItem, PyTuple_Size, PyList_GET_ITEM, PyList_GET_SIZE
from cpython.int cimport PyInt_AsLong
from libc.stdlib cimport malloc, calloc, free
from libc.math cimport log10, log, sqrt, exp

import numpy as np
cimport numpy as np

np.import_array()

from numpy.math cimport isnan

import six
from collections import OrderedDict

from ms_deisotope._c.peak_set cimport DeconvolutedPeak, DeconvolutedPeakSet

from glycan_profiling._c.structure.fragment_match_map cimport (
    FragmentMatchMap, PeakFragmentPair)

from glycopeptidepy._c.structure.base cimport AminoAcidResidueBase, SequencePosition
from glycopeptidepy._c.structure.sequence_methods cimport _PeptideSequenceCore
from glycopeptidepy._c.structure.fragment cimport PeptideFragment, FragmentBase, IonSeriesBase, ChemicalShiftBase

from glypy.utils.enum import Enum
from glypy.utils.cenum cimport EnumValue, IntEnumValue, EnumMeta

from glycopeptidepy.structure.fragment import IonSeries


from feature_learning.amino_acid_classification import (
    AminoAcidClassification, classify_amide_bond_frank)
from feature_learning._c.amino_acid_classification cimport (
    classify_residue_frank)


@six.add_metaclass(EnumMeta)
class FragmentSeriesClassification(object):
    __enum_type__ = IntEnumValue

    b = 0
    y = 1
    stub_glycopeptide = 2
    unassigned = 3


# the number of ion series to consider is one less than the total number of series
# because unassigned is a special case which no matched peaks will receive
cdef int FragmentSeriesClassification_max = max(FragmentSeriesClassification, key=lambda x: x[1].value)[1].value - 1

# the number of backbone ion series to consider is two less because the stub_glycopeptide
# series is not a backbone fragmentation series
cdef int BackboneFragmentSeriesClassification_max = FragmentSeriesClassification_max - 1


cdef int AminoAcidClassification_max = max(AminoAcidClassification, key=lambda x: x[1].value)[1].value


class FragmentTypeClassification(AminoAcidClassification):
    pass

cdef EnumValue FragmentTypeClassification_pro = FragmentTypeClassification.pro


cdef int FragmentTypeClassification_max = max(FragmentTypeClassification, key=lambda x: x[1].value)[1].value

# consider fragments with up to 2 monosaccharides attached to a backbone fragment
cdef int BackboneFragment_max_glycosylation_size = 2
# consider fragments of up to charge 4+
cdef int FragmentCharge_max = 4
# consider up to 10 monosaccharides of glycan still attached to a stub ion
cdef int StubFragment_max_glycosylation_size = 10

cdef:
    EnumValue FragmentSeriesClassification_unassigned = FragmentSeriesClassification.unassigned
    EnumValue FragmentSeriesClassification_stub_glycopeptide = FragmentSeriesClassification.stub_glycopeptide


cpdef int get_nterm_index_from_fragment(PeptideFragment fragment, _PeptideSequenceCore structure):
    cdef:
        IonSeriesBase series
        size_t size
        int direction, index

    series = fragment.get_series()
    size = structure.get_size()
    direction = series.direction
    if direction < 0:
        index = size + (direction * fragment.position + direction)
    else:
        index = fragment.position - 1
    return index


cpdef int get_cterm_index_from_fragment(PeptideFragment fragment, _PeptideSequenceCore structure):
    cdef:
        IonSeriesBase series
        size_t size
        int direction, index

    series = fragment.get_series()
    size = structure.get_size()
    direction = series.direction
    if direction < 0:
        index = size + (series.direction * fragment.position)
    else:
        index = fragment.position
    return index


cdef class _FragmentType(object):

    def __init__(self, nterm, cterm, series, glycosylated, charge, peak_pair, sequence):
        self.nterm = nterm
        self.cterm = cterm
        self.series = series
        self.glycosylated = glycosylated
        self.charge = charge
        self.peak_pair = peak_pair
        self.sequence = sequence

        self._is_assigned = (self.series != FragmentSeriesClassification_unassigned)
        self._is_stub_glycopeptide = (self._is_assigned and self.series == FragmentSeriesClassification_stub_glycopeptide)
        self._is_backbone = (self._is_assigned and self.series != FragmentSeriesClassification_stub_glycopeptide)

    def __iter__(self):
        yield self.nterm
        yield self.cterm
        yield self.series
        yield self.glycosylated
        yield self.charge
        yield self.peak_pair
        yield self.sequence

    def __getitem__(self, int i):
        if i == 0:
            return self.nterm
        elif i == 1:
            return self.cterm
        elif i == 2:
            return self.series
        elif i == 3:
            return self.glycosylated
        elif i == 4:
            return self.charge
        elif i == 5:
            return self.peak_pair
        elif i == 6:
            return self.sequence
        else:
            raise IndexError(i)

    cdef DeconvolutedPeak get_peak(self):
        return self.peak_pair.peak

    cdef FragmentBase get_fragment(self):
        return self.peak_pair.fragment

    @property
    def peak(self):
        return self.get_peak()

    @property
    def fragment(self):
        return self.get_fragment()

    cpdef bint is_assigned(self):
        return self._is_assigned

    cpdef bint is_backbone(self):
        return self._is_backbone

    cpdef bint is_stub_glycopeptide(self):
        return self._is_stub_glycopeptide

    def __str__(self):
        return '(%s, %s, %s, %r, %r)' % (
            self[0].name if self[0] else '',
            self[1].name if self[1] else '',
            self[2].name, self[3], self[4])

    cdef long get_feature_count(self):
        return PyInt_AsLong(type(self).feature_count)        

    cpdef np.ndarray[feature_dtype_t, ndim=1] _allocate_feature_array(self):
        cdef:
            Py_ssize_t k
            np.npy_intp knd

        k = self.get_feature_count()
        knd = k
        return np.PyArray_ZEROS(1, &knd, np.NPY_UINT8, 0)

    cpdef np.ndarray[feature_dtype_t, ndim=1] as_feature_vector(self):
        cdef:
            np.ndarray[feature_dtype_t, ndim=1] X
            size_t offset
        X = self._allocate_feature_array()
        offset = 0
        self.build_feature_vector(X, offset)
        return X

    cpdef build_feature_vector(self, np.ndarray[feature_dtype_t, ndim=1] X, Py_ssize_t offset):
        cdef:
            Py_ssize_t k_ftypes, k_series, k_unassigned, k_charge
            Py_ssize_t k_charge_series, k_glycosylated, k, index

        k_ftypes = (FragmentTypeClassification_max + 1)
        k_series = (FragmentSeriesClassification_max + 1)
        k_unassigned = 1
        k_charge = FragmentCharge_max + 1
        k_charge_series = k_charge * k_series

        k_glycosylated = BackboneFragment_max_glycosylation_size + 1

        k = (
            (k_ftypes * 2) + k_series + k_unassigned + k_charge + k_charge_series +
            k_glycosylated)

        if self.nterm is not None:
            X[self.nterm.int_value()] = 1
        offset += k_ftypes

        if self.cterm is not None:
            X[offset + self.cterm.int_value()] = 1
        offset += k_ftypes

        if self._is_assigned:
            X[offset + self.series.int_value()] = 1
        offset += k_series

        # track the unassigned placeholder observation separately
        X[offset] = int(not self._is_assigned)
        offset += k_unassigned

        # use charge - 1 because there is no 0 charge
        if self._is_backbone:
            X[offset + (self.charge - 1)] = 1
        offset += k_charge

        if self._is_assigned:
            index = (self.series.int_value() * k_charge) + (self.charge - 1)
            X[offset + index] = 1
        offset += k_charge_series

        # non-stub ion glycosylation
        if self._is_backbone:
            X[offset + PyInt_AsLong(
                int(self.peak_pair.fragment.glycosylation_size))] = 1
        offset += k_glycosylated
        return X, offset


@cython.binding(True)
cpdef np.ndarray[feature_dtype_t, ndim=2] encode_classification(cls, list classification):
    cdef:
        size_t i, n, j, k
        _FragmentType row
        np.npy_intp[2] knd
        np.ndarray[feature_dtype_t, ndim=1] features
        np.ndarray[feature_dtype_t, ndim=2] X

    n = PyList_GET_SIZE(classification)
    if n == 0:
        k = 0
        knd[0] = n
        knd[1] = k
        return np.PyArray_ZEROS(2, knd, np.NPY_UINT8, 0)
    i = 0
    row = <_FragmentType>PyList_GET_ITEM(classification, i)
    features = row.as_feature_vector()
    k = row.get_feature_count()
    knd[0] = n
    knd[1] = k
    X = np.PyArray_ZEROS(2, knd, np.NPY_UINT8, 0)
    for j in range(k):
        X[i, j] = features[j]
    for i in range(1, n):
        row = <_FragmentType>PyList_GET_ITEM(classification, i)
        features = row.as_feature_vector()
        for j in range(k):
            X[i, j] = features[j]
    return X

@cython.binding(True)
cpdef from_peak_peptide_fragment_pair(cls, PeakFragmentPair peak_fragment_pair, _PeptideSequenceCore structure):
    cdef:
        DeconvolutedPeak peak
        FragmentBase fragment
    peak = peak_fragment_pair.peak
    fragment = peak_fragment_pair.fragment
    nterm, cterm = classify_amide_bond_frank(*fragment.flanking_amino_acids)
    glycosylation = fragment.is_glycosylated
    inst = cls(
        nterm, cterm, FragmentSeriesClassification[fragment.get_series().name],
        glycosylation, min(peak.charge, FragmentCharge_max + 1),
        peak_fragment_pair, structure)
    return inst

@cython.binding(True)
def build_fragment_intensity_matches(cls, gpsm):

    cdef:
        list fragment_classification, intensities_acc
        np.ndarray[double, ndim=1] intensities
        set counted
        double matched_total, total, unassigned
        FragmentMatchMap solution_map
        PeakFragmentPair peak_fragment_pair
        DeconvolutedPeak peak
        DeconvolutedPeakSet peak_set
        FragmentBase fragment
        IonSeriesBase series
        _PeptideSequenceCore structure
        int glycosylation_size
        size_t i
        np.npy_intp n
    fragment_classification = []
    intensities_acc = []
    matched_total = 0
    peak_set = gpsm.deconvoluted_peak_set
    total = 0
    for i in range(peak_set.get_size()):
        peak = peak_set.getitem(i)
        total += peak.intensity

    structure = gpsm.structure
    counted = set()
    if gpsm.solution_map is None:
        gpsm.match()
    solution_map = <FragmentMatchMap>gpsm.solution_map
    for peak_fragment_pair in solution_map.members:
        peak = peak_fragment_pair.peak
        fragment = peak_fragment_pair.fragment
        if peak._index.neutral_mass not in counted:
            matched_total += peak.intensity
            counted.add(peak._index.neutral_mass)

        series = fragment.get_series()
        if series.name == 'oxonium_ion':
            continue
        intensities_acc.append(peak)
        if series.name == 'stub_glycopeptide':
            glycosylation_size = PyInt_AsLong(fragment.glycosylation_size)
            fragment_classification.append(
                cls(
                    None, None, FragmentSeriesClassification_stub_glycopeptide,
                    min(glycosylation_size, StubFragment_max_glycosylation_size),
                    min(peak.charge, FragmentCharge_max + 1),
                    peak_fragment_pair, structure))
            continue
        inst = from_peak_peptide_fragment_pair(cls, peak_fragment_pair, structure)
        fragment_classification.append(inst)
    n = PyList_GET_SIZE(intensities_acc) + 1
    intensities = np.PyArray_ZEROS(1, &n, np.NPY_DOUBLE, 0)
    for i in range(n - 1):
        peak = <DeconvolutedPeak>PyList_GET_ITEM(intensities_acc, i)
        intensities[i] = peak.intensity
    unassigned = total - matched_total
    intensities[n - 1] = (unassigned)
    ft = cls(None, None, FragmentSeriesClassification_unassigned, 0, 0, None, None)
    fragment_classification.append(ft)
    return fragment_classification, intensities, total


@cython.binding(True)
cpdef EnumValue get_nterm_neighbor(_FragmentType self, int offset=1):
    cdef:
        int index
    index = get_nterm_index_from_fragment(<PeptideFragment>self.get_fragment(), self.sequence)
    index -= offset
    if index < 0:
        return None
    else:
        residue = self.sequence.get(index).amino_acid
        return classify_residue_frank(residue)

@cython.binding(True)
cpdef EnumValue get_cterm_neighbor(_FragmentType self, int offset=1):
    cdef:
        int index
    index = get_cterm_index_from_fragment(<PeptideFragment>self.get_fragment(), self.sequence)
    index += offset
    if index > self.sequence.get_size() - 1:
        return None
    else:
        residue = self.sequence.get(index).amino_acid
        return classify_residue_frank(residue)

@cython.binding(True)
def encode_neighboring_residues(_FragmentType self, np.ndarray[feature_dtype_t, ndim=1] X, Py_ssize_t offset):
    cdef:
        Py_ssize_t k_ftypes, k, start
        long bond_offset_depth
        EnumValue nterm, cterm

    bond_offset_depth = PyInt_AsLong(self.bond_offset_depth)
    k_ftypes = (FragmentTypeClassification_max + 1)
    k = (k_ftypes * 2) * bond_offset_depth

    for _ in range(1, bond_offset_depth + 1):
        if self._is_backbone:
            nterm = get_nterm_neighbor(self, bond_offset_depth)
            if nterm is not None:
                X[offset + nterm.int_value()] = 1
        offset += k_ftypes
    for _ in range(1, bond_offset_depth + 1):
        if self._is_backbone:
            cterm = get_cterm_neighbor(self, bond_offset_depth)
            if cterm is not None:
                X[offset + cterm.int_value()] = 1
        offset += k_ftypes
    return X, offset


@cython.binding(True)
def specialize_proline(_FragmentType self, np.ndarray[feature_dtype_t, ndim=1] X, Py_ssize_t offset):
    cdef:
        Py_ssize_t k_charge_cterm_pro, k_series_cterm_pro, k_glycosylated_proline
        Py_ssize_t k
        int index

    k_charge_cterm_pro = (FragmentCharge_max + 1)
    k_series_cterm_pro = (BackboneFragmentSeriesClassification_max + 1)
    k_glycosylated_proline = BackboneFragment_max_glycosylation_size + 1

    k = (k_charge_cterm_pro + k_series_cterm_pro + k_glycosylated_proline)


    if self.cterm == FragmentTypeClassification_pro:
        index = (self.charge - 1)
        X[offset + index] = 1
        offset += k_charge_cterm_pro
        X[offset + self.series.int_value()] = 1
        offset += k_series_cterm_pro
        X[offset + (<PeptideFragment>self.peak_pair.fragment).get_glycosylation_size()] = 1
        offset += k_glycosylated_proline
    else:
        offset += k
    return X, offset


@cython.binding(True)
def encode_stub_information(_FragmentType self, np.ndarray[feature_dtype_t, ndim=1] X, Py_ssize_t offset):
    cdef:
        Py_ssize_t k_glycosylated_stubs, k_sequence_composition_stubs
        Py_ssize_t k, i, n
        int index, c
        tuple tp_c
        list ctr
        EnumValue tp

    k_glycosylated_stubs = StubFragment_max_glycosylation_size + 1
    k_sequence_composition_stubs = FragmentTypeClassification_max + 1
    k = k_glycosylated_stubs + k_sequence_composition_stubs


    if self._is_stub_glycopeptide:
        X[offset + (self.glycosylated)] = 1
        offset += k_glycosylated_stubs

        ctr = classify_sequence_by_residues(self.sequence)
        n = PyList_GET_SIZE(ctr)
        for i in range(n):
            tp_c = <tuple>PyList_GET_ITEM(ctr, i)
            tp = <EnumValue>PyTuple_GetItem(tp_c, 0)
            c = PyInt_AsLong(<object>PyTuple_GetItem(tp_c, 1))
            X[offset + tp.int_value()] = c
        offset += k_sequence_composition_stubs
    else:
        offset += k_glycosylated_stubs + k_sequence_composition_stubs
    return X, offset


@cython.binding(True)
cpdef int get_cleavage_site_distance_from_center(_FragmentType self):
    cdef:
        int index, center
        size_t seq_size
    index = get_cterm_index_from_fragment(self.get_fragment(), self.sequence)
    seq_size = self.sequence.get_size()
    center = (seq_size / 2)
    return abs(center - index)


@cython.binding(True)
def encode_cleavage_site_distance_from_center(_FragmentType self, np.ndarray[feature_dtype_t, ndim=1] X, Py_ssize_t offset):
    cdef:
        Py_ssize_t k_distance, k_series, k
        long max_distance, series_offset, distance

    max_distance = PyInt_AsLong(self.max_cleavage_site_distance_from_center)
    k_distance = max_distance + 1
    k_series = BackboneFragmentSeriesClassification_max + 1
    k = k_distance * k_series
    if self._is_backbone:
        distance = get_cleavage_site_distance_from_center(self)
        distance = min(distance, max_distance)
        series_offset = self.series.int_value() * k_distance
        X[offset + series_offset + distance] = 1
    offset += (k_distance * k_series)
    return X, offset


@cython.binding(True)
def encode_stub_charge(_FragmentType self, np.ndarray[feature_dtype_t, ndim=1] X, Py_ssize_t offset):
    cdef:
        Py_ssize_t k_glycosylated_stubs, k_stub_charges, k_glycosylated_stubs_x_charge
        Py_ssize_t k
        long loss_size, d

    k_glycosylated_stubs = (StubFragment_max_glycosylation_size * 2) + 1
    k_stub_charges = FragmentCharge_max + 1
    k_glycosylated_stubs_x_charge = (k_glycosylated_stubs * k_stub_charges)
    k = k_glycosylated_stubs_x_charge

    if self._is_stub_glycopeptide:
        loss_size = PyInt_AsLong(self.sequence.total_glycosylation_size) - self.glycosylated
        if loss_size >= k_glycosylated_stubs:
            loss_size = k_glycosylated_stubs - 1
        d = k_glycosylated_stubs * (self.charge - 1) + loss_size
        X[offset + d] = 1
    offset += k_glycosylated_stubs_x_charge
    return X, offset

def classify_sequence_by_residues(_PeptideSequenceCore sequence):
    cdef:
        size_t i, n, m
        int* residue_tp_counts
        AminoAcidResidueBase res
        EnumValue e
        list result

    residue_tp_counts = <int*>calloc(AminoAcidClassification_max, sizeof(int))
    n = sequence.get_size()
    for i in range(n):
        res = sequence.get(i).amino_acid
        e = classify_residue_frank(res)
        residue_tp_counts[e.int_value()] += 1

    result = []
    m = 0
    for i in range(AminoAcidClassification_max):
        if residue_tp_counts[i] > 0:
            m += residue_tp_counts[i]
            result.append((AminoAcidClassification[i], residue_tp_counts[i]))
    result.append((AminoAcidClassification['x'], n - m))
    free(residue_tp_counts)
    return result