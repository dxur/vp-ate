pub fn predict_dcpred<const N: usize>(
    top: &Option<[u8; N]>,
    left: &Option<[u8; N]>,
) -> [[u8; N]; N] {
    let mut shf = match N {
        8 => 3,
        16 => 4,
        _ => unreachable!()
    };

    let sum: i32 = match (top, left) {
        (Some(t), Some(l)) => {
            shf += 1;
            let sum_top: i32 = t.iter().map(|&v| v as i32).sum();
            let sum_left: i32 = l.iter().map(|&v| v as i32).sum();
            sum_top + sum_left
        }
        (Some(t), None) => {
            t.iter().map(|&v| v as i32).sum()
        }
        (None, Some(l)) => {
            l.iter().map(|&v| v as i32).sum()
        }
        (None, None) => return [[128u8; N]; N],
    };

    // int sum;  /* sum of 8 or 16 pixels at (at least) 16-bit precision */
    // int shf;  /* base 2 logarithm of the number of pixels (3 or 4) */

    // Pixel DCvalue = (sum + (1 << (shf-1))) >> shf;
    let dcval = (sum + (1 << (shf-1))) >> shf;

    [[dcval as u8; N]; N]
}

pub fn predict_tmpred<const N: usize>(
    top: &Option<[u8; N]>,
    left: &Option<[u8; N]>,
    top_left: &Option<u8>,
) -> [[u8; N]; N] {
    let a = top.as_ref().unwrap_or(&[127u8; N]);
    let l = left.as_ref().unwrap_or(&[129u8; N]);
    let p = *top_left.as_ref().unwrap_or(if top.is_none() { &127u8 } else { &129u8 });

    let mut out = [[0u8; N]; N];
    for y in 0..N {
        for x in 0..N {
            let pred_i16 = (l[y] as i16) + (a[x] as i16) - (p as i16);
            out[y][x] = clamp255(pred_i16 as i32);
        }
    }
    out
}

pub fn predict_vpred<const N: usize>(top: &Option<[u8; N]>) -> [[u8; N]; N] {
    match top {
        Some(t) => [*t; N],
        None => [[127; N]; N],
    }
}

pub fn predict_hpred<const N: usize>(left: &Option<[u8; N]>) -> [[u8; N]; N] {
    match left {
        Some(l) => {
            let mut out = [[0u8; N]; N];
            for (y, &val) in l.iter().enumerate() {
                out[y] = [val; N];
            }
            out
        }
        None => [[129; N]; N],
    }
}

#[inline]
fn avg3(x: u8, y: u8, z: u8) -> u8 {
    ((x as u16 + y as u16 + y as u16 + z as u16 + 2) >> 2) as u8
}

#[inline]
fn avg2(x: u8, y: u8) -> u8 {
    ((x as u16 + y as u16 + 1) >> 1) as u8
}

#[inline]
fn clamp255(val: i32) -> u8 {
    val.clamp(0, 255) as u8
}

pub fn predict_dcpred_avg(
    top: &Option<[u8; 4]>,
    left: &Option<[u8; 4]>,
) -> [[u8; 4]; 4] {
    let a = top.unwrap_or([127; 4]);
    let l = left.unwrap_or([129; 4]);

    // int v = 4;      /* DC sum/avg, 4 is rounding adjustment */
    // int i = 0;  do { v += A[i] + L[i];}  while (++i < 4);
    // v >>= 3;        /* averaging 8 pixels */
    // i = 0;  do {    /* fill prediction buffer with constant DC
    //                     value */
    //     int j = 0;  do { B[i][j] = v;}  while (++j < 4);
    // } while (++i < 4);
    // break;
    let mut dcval = 4i32;
    for i in 0..4 {
        dcval += a[i] as i32 + l[i] as i32;
    }
    dcval >>= 3;

    [[dcval as u8; 4]; 4]
}

// B_VE_PRED: Vertical prediction with averaging
// All 4 rows = smoothed top row
pub fn predict_vpred_avg(
    top: &Option<[u8; 4]>,
    top_left: &Option<u8>,
    top_right: &Option<[u8; 4]>,
) -> [[u8; 4]; 4] {
    let a = top.unwrap_or([127; 4]);
    let p = top_left.unwrap_or(127);
    let r = top_right.map(|v| v[0]).unwrap_or(a[3]);

    let mut avgs = [0u8; 4];

    for (i, v) in avgs.iter_mut().enumerate() {
        if i == 0 {
            *v = avg3(p, a[0], a[1]);
        } else if i == 3 {
            *v = avg3(a[i - 1], a[i], r);
        } else {
            *v = avg3(a[i - 1], a[i], a[i + 1]);
        }
    }

    [avgs; 4]
}

// B_HE_PRED: Horizontal prediction with averaging
// All 4 columns = smoothed left column
pub fn predict_hpred_avg(
    left: &Option<[u8; 4]>,
    top_left: &Option<u8>,
) -> [[u8; 4]; 4] {
    let l = left.unwrap_or([129; 4]);
    let p = top_left.unwrap_or(127);
    let mut result = [[0; 4]; 4];

    for r in 0..4 {
        let val = if r == 3 {
            avg3(l[2], l[3], l[3])
        } else if r == 0 {
            avg3(p, l[0], l[1])
        } else {
            avg3(l[r - 1], l[r], l[r + 1])
        };

        for c in 0..4 {
            result[r][c] = val;
        }
    }

    result
}


pub fn predict_bldpred(
    top: &Option<[u8; 4]>,
    top_right: &Option<[u8; 4]>,
) -> [[u8; 4]; 4] {
    let a = top.unwrap_or([127; 4]);
    let mut a_ext = [0u8; 8];
    a_ext[0..4].copy_from_slice(&a);

    if let Some(tr) = top_right {
        a_ext[4..8].copy_from_slice(tr);
    } else {
        a_ext[4..8].fill(a[3]);
    }

    let a = a_ext;

    let mut result = [[0u8; 4]; 4];

    // B[0][0] = avg3p(A + 1);
    result[0][0] = avg3(a[0], a[1], a[2]);
    // B[0][1] = B[1][0] = avg3p(A + 2);
    result[0][1] = avg3(a[1], a[2], a[3]);
    result[1][0] = result[0][1];
    // B[0][2] = B[1][1] = B[2][0] = avg3p(A + 3);
    result[0][2] = avg3(a[2], a[3], a[4]);
    result[1][1] = result[0][2];
    result[2][0] = result[0][2];
    // B[0][3] = B[1][2] = B[2][1] = B[3][0] = avg3p(A + 4);
    result[0][3] = avg3(a[3], a[4], a[5]);
    result[1][2] = result[0][3];
    result[2][1] = result[0][3];
    result[3][0] = result[0][3];
    // B[1][3] = B[2][2] = B[3][1] = avg3p(A + 5);
    result[1][3] = avg3(a[4], a[5], a[6]);
    result[2][2] = result[1][3];
    result[3][1] = result[1][3];
    // B[2][3] = B[3][2] = avg3p(A + 6);
    result[2][3] = avg3(a[5], a[6], a[7]);
    result[3][2] = result[2][3];
    // B[3][3] = avg3(A[6], A[7], A[7]); /* A[8] does not exist */
    result[3][3] = avg3(a[6], a[7], a[7]);
    result
}

pub fn predict_brdpred(
    top: &Option<[u8; 4]>,
    left: &Option<[u8; 4]>,
    top_left: &Option<u8>,
) -> [[u8; 4]; 4] {
    let a = top.unwrap_or([127; 4]);
    let l = left.unwrap_or([129; 4]);
    let p = top_left.unwrap_or(127);

    let mut result = [[0u8; 4]; 4];
    let e = [l[3], l[2], l[1], l[0], p, a[0], a[1], a[2], a[3]];

    result[3][0] = avg3(e[0], e[1], e[2]);
    result[3][1] = avg3(e[1], e[2], e[3]);
    result[2][0] = result[3][1];
    result[3][2] = avg3(e[2], e[3], e[4]);
    result[2][1] = result[3][2];
    result[1][0] = result[3][2];
    result[3][3] = avg3(e[3], e[4], e[5]);
    result[2][2] = result[3][3];
    result[1][1] = result[3][3];
    result[0][0] = result[3][3];
    result[2][3] = avg3(e[4], e[5], e[6]);
    result[1][2] = result[2][3];
    result[0][1] = result[2][3];
    result[1][3] = avg3(e[5], e[6], e[7]);
    result[0][2] = result[1][3];
    result[0][3] = avg3(e[6], e[7], e[8]);
    result
}

pub fn predict_bvrpred(
    top: &Option<[u8; 4]>,
    left: &Option<[u8; 4]>,
    top_left: &Option<u8>,
) -> [[u8; 4]; 4] {
    let a = top.unwrap_or([127; 4]);
    let l = left.unwrap_or([129; 4]);
    let p = top_left.unwrap_or(127);

    let mut result = [[0u8; 4]; 4];
    let e = [l[3], l[2], l[1], l[0], p, a[0], a[1], a[2], a[3]];

    // B[3][0] = avg3p(E + 2);  /* predictor is from (1, -1) */
    // B[2][0] = avg3p(E + 3);  /* (0, -1) */
    // B[3][1] = B[1][0] = avg3p(E + 4);  /* (-1,   -1) */
    // B[2][1] = B[0][0] = avg2p(E + 4);  /* (-1, -1/2) */
    // B[3][2] = B[1][1] = avg3p(E + 5);  /* (-1,    0) */
    // B[2][2] = B[0][1] = avg2p(E + 5);  /* (-1,  1/2) */
    // B[3][3] = B[1][2] = avg3p(E + 6);  /* (-1,    1) */
    // B[2][3] = B[0][2] = avg2p(E + 6);  /* (-1,  3/2) */
    // B[1][3] = avg3p(E + 7);  /* (-1, 2) */
    // B[0][3] = avg2p(E + 7);  /* (-1, 5/2) */    //

    result[3][0] = avg3(e[1], e[2], e[3]);
    result[2][0] = avg3(e[2], e[3], e[4]);
    result[3][1] = avg3(e[3], e[4], e[5]);
    result[1][0] = result[3][1];
    result[2][1] = avg2(e[4], e[5]);
    result[0][0] = result[2][1];
    result[3][2] = avg3(e[4], e[5], e[6]);
    result[1][1] = result[3][2];
    result[2][2] = avg2(e[5], e[6]);
    result[0][1] = result[2][2];
    result[3][3] = avg3(e[5], e[6], e[7]);
    result[1][2] = result[3][3];
    result[2][3] = avg2(e[6], e[7]);
    result[0][2] = result[2][3];
    result[1][3] = avg3(e[6], e[7], e[8]);
    result[0][3] = avg2(e[7], e[8]);
    result
}

pub fn predict_bvlpred(
    top: &Option<[u8; 4]>,
    top_right: &Option<[u8; 4]>,
) -> [[u8; 4]; 4] {
    let a = top.unwrap_or([127; 4]);

    let mut a_ext = [0u8; 8];
    a_ext[0..4].copy_from_slice(&a);

    if let Some(tr) = top_right {
        a_ext[4..8].copy_from_slice(tr);
    } else {
        a_ext[4..8].fill(a[3]);
    }

    let a = a_ext;

    let mut result = [[0u8; 4]; 4];

    // B[0][0] = avg2p(A);  /* predictor is from (-1, 1/2) */
    // B[1][0] = avg3p(A + 1);  /* (-1, 1) */
    // B[2][0] = B[0][1] = avg2p(A + 1);  /* (-1, 3/2) */
    // B[1][1] = B[3][0] = avg3p(A + 2);  /* (-1,   2) */
    // B[2][1] = B[0][2] = avg2p(A + 2);  /* (-1, 5/2) */
    // B[3][1] = B[1][2] = avg3p(A + 3);  /* (-1,   3) */
    // B[2][2] = B[0][3] = avg2p(A + 3);  /* (-1, 7/2) */
    // B[3][2] = B[1][3] = avg3p(A + 4);  /* (-1,   4) */
    // /* Last two values do not strictly follow the pattern. */
    // B[2][3] = avg3p(A + 5);  /* (-1, 5) [avg2p(A + 4) =
    //                              (-1,9/2)] */
    // B[3][3] = avg3p(A + 6);  /* (-1, 6) [avg3p(A + 5) =
    //                              (-1,5)] */
    result[0][0] = avg2(a[0], a[1]);
    result[1][0] = avg3(a[0], a[1], a[2]);
    result[2][0] = avg2(a[1], a[2]);
    result[0][1] = result[2][0];
    result[1][1] = avg3(a[1], a[2], a[3]);
    result[3][0] = result[1][1];
    result[2][1] = avg2(a[2], a[3]);
    result[0][2] = result[2][1];
    result[3][1] = avg3(a[2], a[3], a[4]);
    result[1][2] = result[3][1];
    result[2][2] = avg2(a[3], a[4]);
    result[0][3] = result[2][2];
    result[3][2] = avg3(a[3], a[4], a[5]);
    result[1][3] = result[3][2];
    // Last two values do not strictly follow pattern
    result[2][3] = avg3(a[4], a[5], a[6]);
    result[3][3] = avg3(a[5], a[6], a[7]);

    result
}

pub fn predict_bhdpred(
    top: &Option<[u8; 4]>,
    left: &Option<[u8; 4]>,
    top_left: &Option<u8>,
) -> [[u8; 4]; 4] {
    let a = top.unwrap_or([127; 4]);
    let l = left.unwrap_or([129; 4]);
    let p = top_left.unwrap_or(127);

    let mut result = [[0u8; 4]; 4];

    let e = [l[3], l[2], l[1], l[0], p, a[0], a[1], a[2], a[3]];

    // B[3][0] = avg2p(E);  /* predictor is from (5/2, -1) */
    // B[3][1] = avg3p(E + 1);  /* (2, -1) */
    // B[2][0] = B[3][2] = svg2p(E + 1);  /* ( 3/2, -1) */
    // B[2][1] = B[3][3] = avg3p(E + 2);  /* (   1, -1) */
    // B[2][2] = B[1][0] = avg2p(E + 2);  /* ( 1/2, -1) */
    // B[2][3] = B[1][1] = avg3p(E + 3);  /* (   0, -1) */
    // B[1][2] = B[0][0] = avg2p(E + 3);  /* (-1/2, -1) */
    // B[1][3] = B[0][1] = avg3p(E + 4);  /* (  -1, -1) */
    // B[0][2] = avg3p(E + 5);  /* (-1, 0) */
    // B[0][3] = avg3p(E + 6);  /* (-1, 1) */
    result[3][0] = avg2(e[0], e[1]); // (5/2, -1)
    result[3][1] = avg3(e[0], e[1], e[2]); // (2, -1)
    result[2][0] = avg2(e[1], e[2]); // (3/2, -1)
    result[3][2] = result[2][0];
    result[2][1] = avg3(e[1], e[2], e[3]); // (1, -1)
    result[3][3] = result[2][1];
    result[2][2] = avg2(e[2], e[3]); // (1/2, -1)
    result[1][0] = result[2][2];
    result[2][3] = avg3(e[2], e[3], e[4]); // (0, -1)
    result[1][1] = result[2][3];
    result[1][2] = avg2(e[3], e[4]); // (-1/2, -1)
    result[0][0] = result[1][2];
    result[1][3] = avg3(e[3], e[4], e[5]); // (-1, -1)
    result[0][1] = result[1][3];
    result[0][2] = avg3(e[4], e[5], e[6]); // (-1, 0)
    result[0][3] = avg3(e[5], e[6], e[7]); // (-1, 1)

    result
}

pub fn predict_bhupred(left: &Option<[u8; 4]>) -> [[u8; 4]; 4] {
    let l = left.unwrap_or([129; 4]);

    let mut result = [[0u8; 4]; 4];

    // B[0][0] = avg2p(L);  /* predictor is from (1/2, -1) */
    // B[0][1] = avg3p(L + 1);  /* (1, -1) */
    // B[0][2] = B[1][0] = avg2p(L + 1);  /* (3/2, -1) */
    // B[0][3] = B[1][1] = avg3p(L + 2);  /* (  2, -1) */
    // B[1][2] = B[2][0] = avg2p(L + 2);  /* (5/2, -1) */
    // B[1][3] = B[2][1] = avg3(L[2], L[3], L[3]);  /* (3, -1) */    //
    /* Not possible to follow pattern for much of the bottom
    row because no (nearby) already-constructed pixels lie
    on the diagonals in question. */
    // B[2][2] = B[2][3] = B[3][0] = B[3][1] = B[3][2] = B[3][3] = L[3];
    result[0][0] = avg2(l[0], l[1]); // (1/2, -1)
    result[0][1] = avg3(l[0], l[1], l[2]); // (1, -1)
    result[0][2] = avg2(l[1], l[2]); // (3/2, -1)
    result[1][0] = result[0][2];
    result[0][3] = avg3(l[1], l[2], l[3]); // (2, -1)
    result[1][1] = result[0][3];
    result[1][2] = avg2(l[2], l[3]); // (5/2, -1)
    result[2][0] = result[1][2];
    result[1][3] = avg3(l[2], l[3], l[3]); // (3, -1) - L[4] does not exist
    result[2][1] = result[1][3];

    result[2][2] = l[3];
    result[2][3] = l[3];
    result[3][0] = l[3];
    result[3][1] = l[3];
    result[3][2] = l[3];
    result[3][3] = l[3];

    result
}
