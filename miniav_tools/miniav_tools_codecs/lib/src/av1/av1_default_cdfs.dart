// AV1 default CDF tables transcribed verbatim from libaom
// (av1/common/entropymode.c), BSD-2-Clause licensed. Values are the literal
// cumulative-probability arguments to the AOM_CDFn() macros; the helper
// [_cdf] expands them into the iCDF (Q15) layout expected by
// `Av1BoolWriter.writeSymbol` and `Av1BoolReader.readSymbol`:
//
//   cdf[i] = 32768 - cumulative_probability_of(symbol_index <= i)
//   cdf[nsyms - 1] = 0     // last symbol has cumulative 32768
//   cdf[nsyms]     = 0     // adaptation counter slot (we never adapt)
//
// We do not adapt CDFs — the frame header sets
// `disable_cdf_update = 1` and `disable_frame_end_update_cdf = 1`, so the
// decoder uses these defaults frame-for-frame, matching exactly what the
// encoder used.

// ---------------------------------------------------------------------------
// Sizes / constants from libaom.
// ---------------------------------------------------------------------------

const int kIntraModes = 13;
const int kUvIntraModesCflNotAllowed = 13;
const int kUvIntraModesCflAllowed = 14;
const int kKfModeContexts = 5;
const int kSkipContexts = 3;
const int kPartitionContexts = 20; // 4 ctx × 5 block-size groups
const int kExtPartitionTypes = 10;

/// Build a CDF in the iCDF (Q15) layout expected by the range coder, from
/// the cumulative-probability arguments used by `AOM_CDFn(...)`.
List<int> _cdf(List<int> cum) {
  // cum.length == nsyms - 1. Output length = nsyms + 1.
  final out = List<int>.filled(cum.length + 2, 0);
  for (var i = 0; i < cum.length; i++) {
    out[i] = 32768 - cum[i];
  }
  // out[cum.length] = 0  (last symbol: iCDF of full 32768)
  // out[cum.length + 1] = 0  (counter slot — unused)
  return out;
}

// ---------------------------------------------------------------------------
// default_skip_txfm_cdfs[SKIP_CONTEXTS][CDF_SIZE(2)]
// ---------------------------------------------------------------------------

final List<List<int>> defaultSkipTxfmCdfs = [
  _cdf([31671]),
  _cdf([16515]),
  _cdf([4576]),
];

// Convenience: the p15 (prob value == 1) for each skip context. Since CDF
// for binary { 0, 1 } has cumprob(0) = 31671 → prob(1) = 32768 - 31671 = 1097.
// `writeBool(skipFlag, p1)` uses prob-of-1 convention.
final List<int> defaultSkipP1 = [
  32768 - 31671, // 1097
  32768 - 16515, // 16253
  32768 - 4576, // 28192
];

// ---------------------------------------------------------------------------
// default_partition_cdf[PARTITION_CONTEXTS][CDF_SIZE(EXT_PARTITION_TYPES)]
// 20 contexts. Block-size groups (4 contexts each): 8x8, 16x16, 32x32,
// 64x64, 128x128. Sizes:  CDF4 for 8x8, CDF10 for the middle three groups,
// CDF8 for 128x128.
// ---------------------------------------------------------------------------

final List<List<int>> defaultPartitionCdf = [
  // 8x8 (ctx 0..3) — 4 partition types
  _cdf([19132, 25510, 30392]),
  _cdf([13928, 19855, 28540]),
  _cdf([12522, 23679, 28629]),
  _cdf([9896, 18783, 25853]),
  // 16x16 (ctx 4..7) — 10 partition types
  _cdf([15597, 20929, 24571, 26706, 27664, 28821, 29601, 30571, 31902]),
  _cdf([7925, 11043, 16785, 22470, 23971, 25043, 26651, 28701, 29834]),
  _cdf([5414, 13269, 15111, 20488, 22360, 24500, 25537, 26336, 32117]),
  _cdf([2662, 6362, 8614, 20860, 23053, 24778, 26436, 27829, 31171]),
  // 32x32 (ctx 8..11)
  _cdf([18462, 20920, 23124, 27647, 28227, 29049, 29519, 30178, 31544]),
  _cdf([7689, 9060, 12056, 24992, 25660, 26182, 26951, 28041, 29052]),
  _cdf([6015, 9009, 10062, 24544, 25409, 26545, 27071, 27526, 32047]),
  _cdf([1394, 2208, 2796, 28614, 29061, 29466, 29840, 30185, 31899]),
  // 64x64 (ctx 12..15)
  _cdf([20137, 21547, 23078, 29566, 29837, 30261, 30524, 30892, 31724]),
  _cdf([6732, 7490, 9497, 27944, 28250, 28515, 28969, 29630, 30104]),
  _cdf([5945, 7663, 8348, 28683, 29117, 29749, 30064, 30298, 32238]),
  _cdf([870, 1212, 1487, 31198, 31394, 31574, 31743, 31881, 32332]),
  // 128x128 (ctx 16..19) — 8 partition types
  _cdf([27899, 28219, 28529, 32484, 32539, 32619, 32639]),
  _cdf([6607, 6990, 8268, 32060, 32219, 32338, 32371]),
  _cdf([5429, 6676, 7122, 32027, 32227, 32531, 32582]),
  _cdf([711, 966, 1172, 32448, 32538, 32617, 32664]),
];

// ---------------------------------------------------------------------------
// default_kf_y_mode_cdf[5][5][CDF_SIZE(13)]
// 25 contexts; each picks among 13 intra modes for a key-frame luma block.
// Outer index = above-neighbor mode group; inner = left-neighbor mode group.
// ---------------------------------------------------------------------------

final List<List<List<int>>> defaultKfYModeCdf = [
  [
    _cdf([
      15588,
      17027,
      19338,
      20218,
      20682,
      21110,
      21825,
      23244,
      24189,
      28165,
      29093,
      30466,
    ]),
    _cdf([
      12016,
      18066,
      19516,
      20303,
      20719,
      21444,
      21888,
      23032,
      24434,
      28658,
      30172,
      31409,
    ]),
    _cdf([
      10052,
      10771,
      22296,
      22788,
      23055,
      23239,
      24133,
      25620,
      26160,
      29336,
      29929,
      31567,
    ]),
    _cdf([
      14091,
      15406,
      16442,
      18808,
      19136,
      19546,
      19998,
      22096,
      24746,
      29585,
      30958,
      32462,
    ]),
    _cdf([
      12122,
      13265,
      15603,
      16501,
      18609,
      20033,
      22391,
      25583,
      26437,
      30261,
      31073,
      32475,
    ]),
  ],
  [
    _cdf([
      10023,
      19585,
      20848,
      21440,
      21832,
      22760,
      23089,
      24023,
      25381,
      29014,
      30482,
      31436,
    ]),
    _cdf([
      5983,
      24099,
      24560,
      24886,
      25066,
      25795,
      25913,
      26423,
      27610,
      29905,
      31276,
      31794,
    ]),
    _cdf([
      7444,
      12781,
      20177,
      20728,
      21077,
      21607,
      22170,
      23405,
      24469,
      27915,
      29090,
      30492,
    ]),
    _cdf([
      8537,
      14689,
      15432,
      17087,
      17408,
      18172,
      18408,
      19825,
      24649,
      29153,
      31096,
      32210,
    ]),
    _cdf([
      7543,
      14231,
      15496,
      16195,
      17905,
      20717,
      21984,
      24516,
      26001,
      29675,
      30981,
      31994,
    ]),
  ],
  [
    _cdf([
      12613,
      13591,
      21383,
      22004,
      22312,
      22577,
      23401,
      25055,
      25729,
      29538,
      30305,
      32077,
    ]),
    _cdf([
      9687,
      13470,
      18506,
      19230,
      19604,
      20147,
      20695,
      22062,
      23219,
      27743,
      29211,
      30907,
    ]),
    _cdf([
      6183,
      6505,
      26024,
      26252,
      26366,
      26434,
      27082,
      28354,
      28555,
      30467,
      30794,
      32086,
    ]),
    _cdf([
      10718,
      11734,
      14954,
      17224,
      17565,
      17924,
      18561,
      21523,
      23878,
      28975,
      30287,
      32252,
    ]),
    _cdf([
      9194,
      9858,
      16501,
      17263,
      18424,
      19171,
      21563,
      25961,
      26561,
      30072,
      30737,
      32463,
    ]),
  ],
  [
    _cdf([
      12602,
      14399,
      15488,
      18381,
      18778,
      19315,
      19724,
      21419,
      25060,
      29696,
      30917,
      32409,
    ]),
    _cdf([
      8203,
      13821,
      14524,
      17105,
      17439,
      18131,
      18404,
      19468,
      25225,
      29485,
      31158,
      32342,
    ]),
    _cdf([
      8451,
      9731,
      15004,
      17643,
      18012,
      18425,
      19070,
      21538,
      24605,
      29118,
      30078,
      32018,
    ]),
    _cdf([
      7714,
      9048,
      9516,
      16667,
      16817,
      16994,
      17153,
      18767,
      26743,
      30389,
      31536,
      32528,
    ]),
    _cdf([
      8843,
      10280,
      11496,
      15317,
      16652,
      17943,
      19108,
      22718,
      25769,
      29953,
      30983,
      32485,
    ]),
  ],
  [
    _cdf([
      12578,
      13671,
      15979,
      16834,
      19075,
      20913,
      22989,
      25449,
      26219,
      30214,
      31150,
      32477,
    ]),
    _cdf([
      9563,
      13626,
      15080,
      15892,
      17756,
      20863,
      22207,
      24236,
      25380,
      29653,
      31143,
      32277,
    ]),
    _cdf([
      8356,
      8901,
      17616,
      18256,
      19350,
      20106,
      22598,
      25947,
      26466,
      29900,
      30523,
      32261,
    ]),
    _cdf([
      10835,
      11815,
      13124,
      16042,
      17018,
      18039,
      18947,
      22753,
      24615,
      29489,
      30883,
      32482,
    ]),
    _cdf([
      7618,
      8288,
      9859,
      10509,
      15386,
      18657,
      22903,
      28776,
      29180,
      31355,
      31802,
      32593,
    ]),
  ],
];

// ---------------------------------------------------------------------------
// default_uv_mode_cdf[2][13][CDF_SIZE(UV_INTRA_MODES)]
//   Outer 0 = CFL not allowed → 13 UV modes.
//   Outer 1 = CFL allowed     → 14 UV modes.
// Indexed by luma intra mode.
// ---------------------------------------------------------------------------

final List<List<int>> defaultUvModeCdfCflNotAllowed = [
  _cdf([
    22631,
    24152,
    25378,
    25661,
    25986,
    26520,
    27055,
    27923,
    28244,
    30059,
    30941,
    31961,
  ]),
  _cdf([
    9513,
    26881,
    26973,
    27046,
    27118,
    27664,
    27739,
    27824,
    28359,
    29505,
    29800,
    31796,
  ]),
  _cdf([
    9845,
    9915,
    28663,
    28704,
    28757,
    28780,
    29198,
    29822,
    29854,
    30764,
    31777,
    32029,
  ]),
  _cdf([
    13639,
    13897,
    14171,
    25331,
    25606,
    25727,
    25953,
    27148,
    28577,
    30612,
    31355,
    32493,
  ]),
  _cdf([
    9764,
    9835,
    9930,
    9954,
    25386,
    27053,
    27958,
    28148,
    28243,
    31101,
    31744,
    32363,
  ]),
  _cdf([
    11825,
    13589,
    13677,
    13720,
    15048,
    29213,
    29301,
    29458,
    29711,
    31161,
    31441,
    32550,
  ]),
  _cdf([
    14175,
    14399,
    16608,
    16821,
    17718,
    17775,
    28551,
    30200,
    30245,
    31837,
    32342,
    32667,
  ]),
  _cdf([
    12885,
    13038,
    14978,
    15590,
    15673,
    15748,
    16176,
    29128,
    29267,
    30643,
    31961,
    32461,
  ]),
  _cdf([
    12026,
    13661,
    13874,
    15305,
    15490,
    15726,
    15995,
    16273,
    28443,
    30388,
    30767,
    32416,
  ]),
  _cdf([
    19052,
    19840,
    20579,
    20916,
    21150,
    21467,
    21885,
    22719,
    23174,
    28861,
    30379,
    32175,
  ]),
  _cdf([
    18627,
    19649,
    20974,
    21219,
    21492,
    21816,
    22199,
    23119,
    23527,
    27053,
    31397,
    32148,
  ]),
  _cdf([
    17026,
    19004,
    19997,
    20339,
    20586,
    21103,
    21349,
    21907,
    22482,
    25896,
    26541,
    31819,
  ]),
  _cdf([
    12124,
    13759,
    14959,
    14992,
    15007,
    15051,
    15078,
    15166,
    15255,
    15753,
    16039,
    16606,
  ]),
];

final List<List<int>> defaultUvModeCdfCflAllowed = [
  _cdf([
    10407,
    11208,
    12900,
    13181,
    13823,
    14175,
    14899,
    15656,
    15986,
    20086,
    20995,
    22455,
    24212,
  ]),
  _cdf([
    4532,
    19780,
    20057,
    20215,
    20428,
    21071,
    21199,
    21451,
    22099,
    24228,
    24693,
    27032,
    29472,
  ]),
  _cdf([
    5273,
    5379,
    20177,
    20270,
    20385,
    20439,
    20949,
    21695,
    21774,
    23138,
    24256,
    24703,
    26679,
  ]),
  _cdf([
    6740,
    7167,
    7662,
    14152,
    14536,
    14785,
    15034,
    16741,
    18371,
    21520,
    22206,
    23389,
    24182,
  ]),
  _cdf([
    4987,
    5368,
    5928,
    6068,
    19114,
    20315,
    21857,
    22253,
    22411,
    24911,
    25380,
    26027,
    26376,
  ]),
  _cdf([
    5370,
    6889,
    7247,
    7393,
    9498,
    21114,
    21402,
    21753,
    21981,
    24780,
    25386,
    26517,
    27176,
  ]),
  _cdf([
    4816,
    4961,
    7204,
    7326,
    8765,
    8930,
    20169,
    20682,
    20803,
    23188,
    23763,
    24455,
    24940,
  ]),
  _cdf([
    6608,
    6740,
    8529,
    9049,
    9257,
    9356,
    9735,
    18827,
    19059,
    22336,
    23204,
    23964,
    24793,
  ]),
  _cdf([
    5998,
    7419,
    7781,
    8933,
    9255,
    9549,
    9753,
    10417,
    18898,
    22494,
    23139,
    24764,
    25989,
  ]),
  _cdf([
    10660,
    11298,
    12550,
    12957,
    13322,
    13624,
    14040,
    15004,
    15534,
    20714,
    21789,
    23443,
    24861,
  ]),
  _cdf([
    10522,
    11530,
    12552,
    12963,
    13378,
    13779,
    14245,
    15235,
    15902,
    20102,
    22696,
    23774,
    25838,
  ]),
  _cdf([
    10099,
    10691,
    12639,
    13049,
    13386,
    13665,
    14125,
    15163,
    15636,
    19676,
    20474,
    23519,
    25208,
  ]),
  _cdf([
    3144,
    5087,
    7382,
    7504,
    7593,
    7690,
    7801,
    8064,
    8232,
    9248,
    9875,
    10521,
    29048,
  ]),
];

// ===========================================================================
// Coefficient coding CDFs — TX_4X4, 8-bit, from libaom entropymode.c
// All tables keyed as: [plane_type 0=luma / 1=chroma][context]
// ===========================================================================

// ---------------------------------------------------------------------------
// default_eob_flag_cdf4[PLANE_TYPES][EOB_COEF_CONTEXTS]
// EOB_COEF_CONTEXTS = 4 for TX_4X4.
// Each CDF selects among 11 EOB positions (1..16): the position at which
// the last non-zero coeff lives, in scan order. The CDF is over [0..10].
// (EobPt11 = 11 symbols.)
// ---------------------------------------------------------------------------
final List<List<List<int>>> defaultEobFlagCdf4 = [
  // luma
  [
    _cdf([
      17837,
      20494,
      22500,
      23581,
      24296,
      25382,
      26061,
      27419,
      28724,
      30439,
    ]),
    _cdf([
      12534,
      14350,
      16530,
      17878,
      18882,
      20327,
      21390,
      23437,
      25337,
      28259,
    ]),
    _cdf([6571, 8208, 10072, 11399, 12562, 14228, 15507, 18374, 21116, 25606]),
    _cdf([4486, 5840, 7519, 8792, 9840, 11552, 12953, 16192, 19313, 24677]),
  ],
  // chroma
  [
    _cdf([
      17617,
      20650,
      22543,
      23723,
      24562,
      25766,
      26572,
      28041,
      29371,
      31297,
    ]),
    _cdf([
      10565,
      12543,
      14570,
      15895,
      16901,
      18417,
      19573,
      21893,
      24080,
      27384,
    ]),
    _cdf([3044, 4089, 5612, 7018, 8241, 10499, 12283, 16386, 20148, 26306]),
    _cdf([3050, 4084, 5721, 7014, 8132, 10124, 11830, 15918, 19890, 26190]),
  ],
];

// ---------------------------------------------------------------------------
// default_coeff_base_eob_cdf[TX_SIZES][PLANE_TYPES][SIG_COEF_CONTEXTS_EOB]
// SIG_COEF_CONTEXTS_EOB = 3 for TX_4X4.
// 3 symbols: 0=zero, 1=one, 2=more.
// ---------------------------------------------------------------------------
final List<List<List<List<int>>>> defaultCoeffBaseEobCdf = [
  // TX_4X4
  [
    // luma
    [
      _cdf([16049, 24932]),
      _cdf([20040, 26499]),
      _cdf([23479, 28532]),
    ],
    // chroma
    [
      _cdf([17479, 25557]),
      _cdf([20678, 27011]),
      _cdf([22384, 27941]),
    ],
  ],
];

// ---------------------------------------------------------------------------
// default_coeff_base_cdf[TX_SIZES][PLANE_TYPES][SIG_COEF_CONTEXTS]
// SIG_COEF_CONTEXTS = 42 for TX_4X4.
// 4 symbols: 0=zero, 1=one, 2=two, 3=more.
// ---------------------------------------------------------------------------
final List<List<List<List<int>>>> defaultCoeffBaseCdf = [
  // TX_4X4
  [
    // luma (42 contexts)
    [
      _cdf([5283, 10553, 18971]),
      _cdf([4685, 9529, 17936]),
      _cdf([4546, 8848, 17048]),
      _cdf([3643, 7339, 14643]),
      _cdf([2183, 4753, 10490]),
      _cdf([4510, 9888, 18882]),
      _cdf([5048, 10461, 19437]),
      _cdf([4453, 9173, 17531]),
      _cdf([3383, 6825, 13461]),
      _cdf([1900, 3994, 9218]),
      _cdf([3671, 7811, 15575]),
      _cdf([4487, 9416, 18095]),
      _cdf([4157, 8640, 16765]),
      _cdf([3462, 7129, 13914]),
      _cdf([2155, 4616, 10416]),
      _cdf([3685, 8253, 16434]),
      _cdf([4510, 9352, 18023]),
      _cdf([4097, 8482, 16407]),
      _cdf([3516, 7228, 14177]),
      _cdf([2128, 4594, 10567]),
      _cdf([2795, 6509, 13753]),
      _cdf([3747, 8015, 15893]),
      _cdf([3797, 7920, 15606]),
      _cdf([3341, 6939, 13808]),
      _cdf([2134, 4644, 10956]),
      _cdf([2168, 5078, 11580]),
      _cdf([3341, 7265, 15164]),
      _cdf([3487, 7430, 15421]),
      _cdf([3168, 6809, 14029]),
      _cdf([2101, 4667, 10764]),
      _cdf([2344, 5765, 13440]),
      _cdf([3410, 7394, 15810]),
      _cdf([3397, 7268, 14888]),
      _cdf([3136, 6664, 13879]),
      _cdf([2091, 4656, 10766]),
      _cdf([2209, 5575, 13528]),
      _cdf([3490, 7513, 16254]),
      _cdf([3494, 7393, 15651]),
      _cdf([3079, 6505, 13707]),
      _cdf([1882, 4197, 10177]),
      _cdf([1806, 4523, 11261]),
      _cdf([2965, 6671, 14946]),
    ],
    // chroma (42 contexts)
    [
      _cdf([4226, 8750, 16754]),
      _cdf([3783, 7915, 15589]),
      _cdf([3618, 7337, 14610]),
      _cdf([2889, 5956, 12190]),
      _cdf([1561, 3417, 8078]),
      _cdf([4428, 9649, 18923]),
      _cdf([4959, 10317, 19768]),
      _cdf([4357, 9077, 17692]),
      _cdf([3296, 6735, 13444]),
      _cdf([1835, 3920, 9170]),
      _cdf([3803, 8205, 16423]),
      _cdf([4548, 9584, 18621]),
      _cdf([4139, 8668, 17042]),
      _cdf([3442, 7059, 13928]),
      _cdf([2095, 4533, 10498]),
      _cdf([3744, 8528, 17024]),
      _cdf([4540, 9618, 18705]),
      _cdf([4148, 8673, 17061]),
      _cdf([3467, 7126, 14057]),
      _cdf([2096, 4550, 10596]),
      _cdf([2852, 6714, 14364]),
      _cdf([3869, 8279, 16606]),
      _cdf([3757, 7930, 15831]),
      _cdf([3292, 6844, 13689]),
      _cdf([2025, 4488, 10645]),
      _cdf([2215, 5261, 12015]),
      _cdf([3480, 7630, 16076]),
      _cdf([3560, 7749, 15933]),
      _cdf([3232, 6862, 13988]),
      _cdf([2051, 4571, 10773]),
      _cdf([2390, 5975, 13879]),
      _cdf([3567, 7723, 16511]),
      _cdf([3597, 7651, 15847]),
      _cdf([3174, 6694, 13985]),
      _cdf([2122, 4793, 11201]),
      _cdf([2349, 5975, 14036]),
      _cdf([3516, 7673, 16515]),
      _cdf([3547, 7548, 15834]),
      _cdf([3146, 6651, 13836]),
      _cdf([1945, 4367, 10456]),
      _cdf([1859, 4680, 11568]),
      _cdf([2985, 6746, 14878]),
    ],
  ],
];

// ---------------------------------------------------------------------------
// qcat=1 coeff_br_cdf for TX_4X4, level_ctx = 0.
// (DC at scan-pos 0 with no other coded coefs → ctx 0.)
// dav1d 1.4.2 cdf.c default_coef_cdf[1].br_tok[TX_4X4][luma/chroma][0].
// ---------------------------------------------------------------------------
final List<List<int>> coefBrTokTx4Qcat1Ctx0 = [
  _cdf([14995, 21341, 24749]), // luma
  _cdf([15571, 22232, 25749]), // chroma
];

// ---------------------------------------------------------------------------
// default_coeff_br_cdf[TX_SIZES][PLANE_TYPES][LEVEL_CONTEXTS]
// LEVEL_CONTEXTS = 21.  4 symbols: 0..3  (br range levels).
// ---------------------------------------------------------------------------
final List<List<List<List<int>>>> defaultCoeffBrCdf = [
  // TX_4X4
  [
    // luma
    [
      _cdf([6358, 8707, 14462]),
      _cdf([9607, 13286, 21125]),
      _cdf([11654, 16118, 24279]),
      _cdf([13251, 18010, 26143]),
      _cdf([14030, 18993, 27063]),
      _cdf([12900, 16991, 24708]),
      _cdf([14460, 18856, 26839]),
      _cdf([15361, 20003, 27993]),
      _cdf([14870, 19576, 27945]),
      _cdf([13803, 18417, 27033]),
      _cdf([12688, 16965, 25239]),
      _cdf([13975, 18566, 27082]),
      _cdf([15293, 20013, 28255]),
      _cdf([15007, 19821, 28159]),
      _cdf([13790, 18412, 27116]),
      _cdf([12540, 16935, 25092]),
      _cdf([13397, 17838, 26394]),
      _cdf([14810, 19394, 27783]),
      _cdf([14571, 19319, 28012]),
      _cdf([13490, 18090, 27016]),
      _cdf([11704, 15597, 23883]),
    ],
    // chroma
    [
      _cdf([5362, 7704, 13371]),
      _cdf([8607, 12426, 20451]),
      _cdf([10663, 14905, 23439]),
      _cdf([12325, 17272, 25803]),
      _cdf([13399, 18271, 26897]),
      _cdf([11505, 15433, 23548]),
      _cdf([13253, 17737, 26005]),
      _cdf([14310, 19006, 27397]),
      _cdf([13860, 18600, 27186]),
      _cdf([13121, 17778, 26638]),
      _cdf([11563, 15870, 24099]),
      _cdf([13217, 17908, 26500]),
      _cdf([14523, 19264, 27908]),
      _cdf([14298, 19055, 27677]),
      _cdf([13238, 17924, 26809]),
      _cdf([11654, 15805, 24050]),
      _cdf([12942, 17270, 25918]),
      _cdf([14219, 18955, 27588]),
      _cdf([14117, 18900, 27610]),
      _cdf([13220, 17934, 26962]),
      _cdf([11498, 15396, 23888]),
    ],
  ],
];

// ---------------------------------------------------------------------------
// default_dc_sign_cdf[PLANE_TYPES][DC_SIGN_CONTEXTS]
// DC_SIGN_CONTEXTS = 3.  2 symbols: 0=positive, 1=negative.
// ---------------------------------------------------------------------------
final List<List<List<int>>> defaultDcSignCdf = [
  // luma   — dav1d: { CDF1(16000), CDF1(13056), CDF1(18816) }
  [
    _cdf([16000]),
    _cdf([13056]),
    _cdf([18816]),
  ],
  // chroma — dav1d: { CDF1(15232), CDF1(12928), CDF1(17280) }
  [
    _cdf([15232]),
    _cdf([12928]),
    _cdf([17280]),
  ],
];

// ---------------------------------------------------------------------------
// default_intra_ext_tx_cdf — TX_TYPES set "intra2" (reduced_tx_set=1,
// TX_4X4/TX_8X8/TX_16X16 intra).  Indexed [txSizeSqr][intraMode][5 syms].
// 5 symbols enumerate EXT_TX_SET_DTT4_IDTX:
//   {DCT_DCT, ADST_DCT, DCT_ADST, ADST_ADST, IDTX}.
//
// Per dav1d `src/cdf.c` (default_cdf): txtp_intra2[t_dim->min=0][DC_PRED]
// is the uniform CDF4(6554,13107,19661,26214).  We only need TX_4X4 +
// DC_PRED for our encoder; everything else is filled with the same uniform
// default for safety (we always emit DC_PRED at TX_4X4 anyway).
// ---------------------------------------------------------------------------
final List<int> defaultTxtpIntra2DcPredCdf = _cdf([6554, 13107, 19661, 26214]);

// ---------------------------------------------------------------------------
// default_cdf.m.txtp_inter3[EXT_TX_SIZES] — inter tx_type for the reduced
// tx-set (reduced_tx_set=1). dav1d `src/cdf.c`:
//   txtp_inter3 = { CDF1(16384), CDF1(4167), CDF1(1998), CDF1(748) }
// indexed by t_dim->min (TX_4X4=0, TX_8X8=1, ...). We only code TX_4X4, so
// index 0 = CDF1(16384). dav1d decode_coefs does
//   idx = msac_bool(txtp_inter3[min]);  *txtp = (idx - 1) & IDTX;
// IDTX=9 ⇒ idx=1 yields (0)&9 = DCT_DCT; idx=0 yields (-1)&9 = IDTX. So to
// encode DCT_DCT we emit the bool VALUE 1 on this CDF.
final List<int> defaultTxtpInter3Tx4Cdf = _cdf([16384]);

// ---------------------------------------------------------------------------
// dav1d-derived coefficient CDFs for qcat=1 (base_q_idx in 20..60).  All of
// the values below are transcribed verbatim from dav1d 1.4.2
// `src/cdf.c` `default_coef_cdf[1]` (the qcat=1 entry, since our encoder
// uses base_q_idx=32 which maps to qcat=1).
//
// Contexts for `txb_skip`:
//   * Luma at BLOCK_4X4 + TX_4X4 always uses ctx = 0 (the block dim
//     matches the transform dim, so dav1d `get_skip_ctx` short-circuits).
//   * Chroma uses ctx = 7 + (above_nonzero) + (left_nonzero), i.e. 7, 8
//     or 9 depending on neighbour state.
// ---------------------------------------------------------------------------
final List<List<int>> coefTxbSkipTx4Qcat1 = [
  _cdf([30371]), // 0  luma  (above=0,left=0,bdim==txdim → always 0)
  _cdf([7570]),
  _cdf([13155]),
  _cdf([20751]),
  _cdf([20969]),
  _cdf([27067]),
  _cdf([32013]),
  _cdf([5495]), //  7  chroma  (above=0,left=0)
  _cdf([17942]), // 8  chroma  (above+left == 1)
  _cdf([28280]), // 9  chroma  (above+left == 2)
  _cdf([16384]),
  _cdf([16384]),
  _cdf([16384]),
];

// eob_bin_16 (TX_4X4) at qcat=1.  Shape in dav1d is
// `[plane][sub_eob_ctx][CDF4]`.  For our DC-only path we use sub_eob_ctx=0.
final List<List<int>> coefEobBin16Qcat1 = [
  // plane = 0 (luma) sub_eob_ctx = 0
  _cdf([2125, 2551, 5165, 8946]),
  // plane = 1 (chroma) sub_eob_ctx = 0
  _cdf([7637, 9498, 14259, 19108]),
];

// eob_base_tok (TX_4X4) at qcat=1, plane × eob_ctx (3 sym CDF: lvl1/2/3+).
// First entry of each list is eob_ctx=0 which is what TX_4X4 always uses.
final List<List<int>> coefEobBaseTokTx4Qcat1 = [
  _cdf([17560, 29888]), // luma   ctx 0
  _cdf([26594, 31212]), // chroma ctx 0
];

// ===========================================================================
// qcat=0 coefficient CDFs (base_q_idx in [1,20]).  Transcribed verbatim from
// dav1d 1.4.2 `src/cdf.c` `default_coef_cdf[0]` for TX_4X4.  Used by the
// full DC+AC residual encoder (baseQIdx<=20 maps to qcat=0).  Stored values
// are the dav1d CDFn cumulative arguments — pass directly to `_cdf`.
// ===========================================================================

// txb_skip[TX_4X4] — 13 contexts.  Luma BLOCK_4X4+TX_4X4 uses ctx 0; chroma
// uses ctx 7 + above + left (7,8,9).
final List<List<int>> coefSkipTx4Qcat0 = [
  _cdf([31849]), // 0  luma
  _cdf([5892]),
  _cdf([12112]),
  _cdf([21935]),
  _cdf([20289]),
  _cdf([27473]),
  _cdf([32487]),
  _cdf([7654]), //  7  chroma above=0 left=0
  _cdf([19473]), // 8  chroma above+left==1
  _cdf([29984]), // 9  chroma above+left==2
  _cdf([9961]),
  _cdf([30242]),
  _cdf([32117]),
];

// eob_bin_16[plane][is_1d] (TX_4X4).  We only emit 2D (is_1d=0).
final List<List<int>> coefEobBin16Tx4Qcat0 = [
  _cdf([840, 1039, 1980, 4895]), // luma   is_1d=0
  _cdf([3247, 4950, 9688, 14563]), // chroma is_1d=0
];

// eob_hi_bit[plane][eob_bin] (TX_4X4), CDF1.  Only eob_bin 2,3,4 are reachable
// for a 16-coefficient transform; indices 0,1,5..10 are filler.
final List<List<List<int>>> coefEobHiBitTx4Qcat0 = [
  // luma
  [
    _cdf([16384]), // 0 unused
    _cdf([16384]), // 1 unused
    _cdf([16961]), // 2
    _cdf([17223]), // 3
    _cdf([7621]), // 4
    _cdf([16384]),
    _cdf([16384]),
    _cdf([16384]),
    _cdf([16384]),
    _cdf([16384]),
    _cdf([16384]),
  ],
  // chroma
  [
    _cdf([16384]),
    _cdf([16384]),
    _cdf([19069]), // 2
    _cdf([22525]), // 3
    _cdf([13377]), // 4
    _cdf([16384]),
    _cdf([16384]),
    _cdf([16384]),
    _cdf([16384]),
    _cdf([16384]),
    _cdf([16384]),
  ],
];

// eob_base_tok[plane][eob_ctx] (TX_4X4), 4 contexts, CDF2.
final List<List<List<int>>> coefEobBaseTokTx4Qcat0 = [
  // luma
  [
    _cdf([17837, 29055]),
    _cdf([29600, 31446]),
    _cdf([30844, 31878]),
    _cdf([24926, 28948]),
  ],
  // chroma
  [
    _cdf([21365, 30026]),
    _cdf([30512, 32423]),
    _cdf([31658, 32621]),
    _cdf([29630, 31881]),
  ],
];

// base_tok[plane][42 ctx] (TX_4X4), CDF3.  Contexts 11..20 and 41 are filler
// (never reachable for TX_4X4) — set to the uniform CDF.
final List<List<List<int>>> coefBaseTokTx4Qcat0 = [
  // luma
  [
    _cdf([4034, 8930, 12727]),
    _cdf([18082, 29741, 31877]),
    _cdf([12596, 26124, 30493]),
    _cdf([9446, 21118, 27005]),
    _cdf([6308, 15141, 21279]),
    _cdf([2463, 6357, 9783]),
    _cdf([20667, 30546, 31929]),
    _cdf([13043, 26123, 30134]),
    _cdf([8151, 18757, 24778]),
    _cdf([5255, 12839, 18632]),
    _cdf([2820, 7206, 11161]),
    _cdf([8192, 16384, 24576]), // 11 filler
    _cdf([8192, 16384, 24576]),
    _cdf([8192, 16384, 24576]),
    _cdf([8192, 16384, 24576]),
    _cdf([8192, 16384, 24576]),
    _cdf([8192, 16384, 24576]),
    _cdf([8192, 16384, 24576]),
    _cdf([8192, 16384, 24576]),
    _cdf([8192, 16384, 24576]),
    _cdf([8192, 16384, 24576]), // 20 filler
    _cdf([15736, 27553, 30604]),
    _cdf([11210, 23794, 28787]),
    _cdf([5947, 13874, 19701]),
    _cdf([4215, 9323, 13891]),
    _cdf([2833, 6462, 10059]),
    _cdf([19605, 30393, 31582]),
    _cdf([13523, 26252, 30248]),
    _cdf([8446, 18622, 24512]),
    _cdf([3818, 10343, 15974]),
    _cdf([1481, 4117, 6796]),
    _cdf([22649, 31302, 32190]),
    _cdf([14829, 27127, 30449]),
    _cdf([8313, 17702, 23304]),
    _cdf([3022, 8301, 12786]),
    _cdf([1536, 4412, 7184]),
    _cdf([22354, 29774, 31372]),
    _cdf([14723, 25472, 29214]),
    _cdf([6673, 13745, 18662]),
    _cdf([2068, 5766, 9322]),
    _cdf([8192, 16384, 24576]), // 40 filler
    _cdf([8192, 16384, 24576]), // 41 filler
  ],
  // chroma
  [
    _cdf([6302, 16444, 21761]),
    _cdf([23040, 31538, 32475]),
    _cdf([15196, 28452, 31496]),
    _cdf([10020, 22946, 28514]),
    _cdf([6533, 16862, 23501]),
    _cdf([3538, 9816, 15076]),
    _cdf([24444, 31875, 32525]),
    _cdf([15881, 28924, 31635]),
    _cdf([9922, 22873, 28466]),
    _cdf([6527, 16966, 23691]),
    _cdf([4114, 11303, 17220]),
    _cdf([8192, 16384, 24576]), // 11 filler
    _cdf([8192, 16384, 24576]),
    _cdf([8192, 16384, 24576]),
    _cdf([8192, 16384, 24576]),
    _cdf([8192, 16384, 24576]),
    _cdf([8192, 16384, 24576]),
    _cdf([8192, 16384, 24576]),
    _cdf([8192, 16384, 24576]),
    _cdf([8192, 16384, 24576]),
    _cdf([8192, 16384, 24576]), // 20 filler
    _cdf([20201, 30770, 32209]),
    _cdf([14754, 28071, 31258]),
    _cdf([8378, 20186, 26517]),
    _cdf([5916, 15299, 21978]),
    _cdf([4268, 11583, 17901]),
    _cdf([24361, 32025, 32581]),
    _cdf([18673, 30105, 31943]),
    _cdf([10196, 22244, 27576]),
    _cdf([5495, 14349, 20417]),
    _cdf([2676, 7415, 11498]),
    _cdf([24678, 31958, 32585]),
    _cdf([18629, 29906, 31831]),
    _cdf([9364, 20724, 26315]),
    _cdf([4641, 12318, 18094]),
    _cdf([2758, 7387, 11579]),
    _cdf([25433, 31842, 32469]),
    _cdf([18795, 29289, 31411]),
    _cdf([7644, 17584, 23592]),
    _cdf([3408, 9014, 15047]),
    _cdf([8192, 16384, 24576]), // 40 filler
    _cdf([8192, 16384, 24576]), // 41 filler
  ],
];

// br_tok[plane][21 ctx] (TX_4X4), CDF3.
final List<List<List<int>>> coefBrTokTx4Qcat0 = [
  // luma
  [
    _cdf([14298, 20718, 24174]),
    _cdf([12536, 19601, 23789]),
    _cdf([8712, 15051, 19503]),
    _cdf([6170, 11327, 15434]),
    _cdf([4742, 8926, 12538]),
    _cdf([3803, 7317, 10546]),
    _cdf([1696, 3317, 4871]),
    _cdf([14392, 19951, 22756]),
    _cdf([15978, 23218, 26818]),
    _cdf([12187, 19474, 23889]),
    _cdf([9176, 15640, 20259]),
    _cdf([7068, 12655, 17028]),
    _cdf([5656, 10442, 14472]),
    _cdf([2580, 4992, 7244]),
    _cdf([12136, 18049, 21426]),
    _cdf([13784, 20721, 24481]),
    _cdf([10836, 17621, 21900]),
    _cdf([8372, 14444, 18847]),
    _cdf([6523, 11779, 16000]),
    _cdf([5337, 9898, 13760]),
    _cdf([3034, 5860, 8462]),
  ],
  // chroma
  [
    _cdf([15967, 22905, 26286]),
    _cdf([13534, 20654, 24579]),
    _cdf([9504, 16092, 20535]),
    _cdf([6975, 12568, 16903]),
    _cdf([5364, 10091, 14020]),
    _cdf([4357, 8370, 11857]),
    _cdf([2506, 4934, 7218]),
    _cdf([23032, 28815, 30936]),
    _cdf([19540, 26704, 29719]),
    _cdf([15158, 22969, 27097]),
    _cdf([11408, 18865, 23650]),
    _cdf([8885, 15448, 20250]),
    _cdf([7108, 12853, 17416]),
    _cdf([4231, 8041, 11480]),
    _cdf([19823, 26490, 29156]),
    _cdf([18890, 25929, 28932]),
    _cdf([15660, 23491, 27433]),
    _cdf([12147, 19776, 24488]),
    _cdf([9728, 16774, 21649]),
    _cdf([7919, 14277, 19066]),
    _cdf([5440, 10170, 14185]),
  ],
];

// ===========================================================================
// INTER-frame mode CDFs.  Transcribed verbatim from dav1d 1.4.2 `src/cdf.c`
// `default_cdf.m` (the values inside the CDF1()/CDFn() macros — pass to
// [_cdf], which applies the 32768-x transform).  These are the *default*
// (non-adapted) tables, valid because our inter frame header pins
// primary_ref_frame = PRIMARY_REF_NONE and disable_cdf_update = 1.
//
// Only the subset needed for the Phase-1 all-GLOBALMV / single-ref-LAST /
// skip inter frame is required at decode time, but the full tables are
// transcribed so the per-block contexts can index any entry.
// ===========================================================================

// m.intra (a.k.a. intra_inter / is_inter), 4 contexts, CDF2 (binary).
// Symbol 0 = inter? In dav1d: `intra = msac_decode_bool_adapt(intra[ctx])`,
// so a decoded bit of 1 => intra, 0 => inter.  Encoder writes the matching
// symbol via writeSymbol with this CDF.
final List<List<int>> defaultIntraInterCdf = [
  _cdf([806]),
  _cdf([16662]),
  _cdf([20186]),
  _cdf([26538]),
];

// m.y_mode (default_if_y_mode_cdf) — inter-frame intra luma mode, indexed by
// dav1d_ymode_size_context[bs] (4 block-size groups), CDF13 (13 intra modes).
// For BLOCK_4X4 the size context is 0, so only group 0 is exercised here, but
// all four groups are transcribed for completeness. Unlike kf_y_mode (which is
// conditioned on the neighbour modes), this is conditioned only on block size.
final List<List<int>> defaultIfYModeCdf = [
  _cdf([
    22801, 23489, 24293, 24756, 25601, 26123, //
    26606, 27418, 27945, 29228, 29685, 30349,
  ]),
  _cdf([
    18673, 19845, 22631, 23318, 23950, 24649, //
    25527, 27364, 28152, 29701, 29984, 30852,
  ]),
  _cdf([
    19770, 20979, 23396, 23939, 24241, 24654, //
    25136, 27073, 27830, 29360, 29730, 30659,
  ]),
  _cdf([
    20155, 21301, 22838, 23178, 23261, 23533, //
    23703, 24804, 25352, 26575, 27016, 28049,
  ]),
];

// m.comp (comp_inter — single vs compound reference), 5 contexts, CDF2.
// Not emitted while reference_mode = SINGLE_REFERENCE, but transcribed for
// completeness.
final List<List<int>> defaultCompInterCdf = [
  _cdf([26828]),
  _cdf([24035]),
  _cdf([12031]),
  _cdf([10640]),
  _cdf([2901]),
];

// m.ref (single_ref) — [6 single-ref-context-groups][3 contexts each], CDF2.
// dav1d indexes this as m.ref[n][ctx] where n in 0..5 selects which binary
// decision in the single-reference tree, and ctx in 0..2 is the neighbour-
// derived context.  Reaching LAST_FRAME uses n=0 (bit 0), n=1 (bit 0),
// n=3 (bit 0) per the AV1 single-reference tree.
final List<List<List<int>>> defaultSingleRefCdf = [
  [
    _cdf([4897]),
    _cdf([16973]),
    _cdf([29744]),
  ], // ref[0]
  [
    _cdf([1555]),
    _cdf([16751]),
    _cdf([30279]),
  ], // ref[1]
  [
    _cdf([4236]),
    _cdf([19647]),
    _cdf([31194]),
  ], // ref[2]
  [
    _cdf([8650]),
    _cdf([24773]),
    _cdf([31895]),
  ], // ref[3]
  [
    _cdf([904]),
    _cdf([11014]),
    _cdf([26875]),
  ], // ref[4]
  [
    _cdf([1444]),
    _cdf([15087]),
    _cdf([30304]),
  ], // ref[5]
];

// m.newmv_mode (newmv), 6 contexts, CDF2.
final List<List<int>> defaultNewMvCdf = [
  _cdf([24035]),
  _cdf([16630]),
  _cdf([15339]),
  _cdf([8386]),
  _cdf([12222]),
  _cdf([4676]),
];

// m.globalmv_mode (globalmv vs near group), 2 contexts, CDF2.
final List<List<int>> defaultGlobalMvCdf = [
  _cdf([2175]),
  _cdf([1054]),
];

// m.refmv_mode (nearestmv vs nearmv), 6 contexts, CDF2.
final List<List<int>> defaultRefMvCdf = [
  _cdf([23974]),
  _cdf([24188]),
  _cdf([17848]),
  _cdf([28622]),
  _cdf([24312]),
  _cdf([19923]),
];

// m.drl_bit (dynamic ref-list selection), 3 contexts, CDF2.  GLOBALMV does
// not read DRL, but transcribed for Phase 3.
final List<List<int>> defaultDrlMvCdf = [
  _cdf([13104]),
  _cdf([24560]),
  _cdf([18945]),
];
