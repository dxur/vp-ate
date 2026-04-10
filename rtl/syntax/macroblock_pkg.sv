package Macroblock;
  typedef enum logic [3-1:0] {
    IntraMBMode_DcPred,  /* predict DC using row above and column to the left */
    IntraMBMode_VPred,   /* predict rows using row above */
    IntraMBMode_HPred,   /* predict columns using column to the left */
    IntraMBMode_TmPred,  /* propagate second differences a la "True Motion" */
    IntraMBMode_BPred    /* each Y subblock is independently predicted */
  } IntraMBMode;

  typedef enum logic [4-1:0] {
    IntraBMode_BDcPred,  /* predict DC using row above and column to the left */
    IntraBMode_BTmPred,  /* propagate second differences a la "True Motion" */
    IntraBMode_BVePred,  /* predict rows using row above */
    IntraBMode_BHePred,  /* predict columns using column to the left */
    IntraBMode_BLdPred,  /* southwest (left and down) 45 degree diagonal prediction */
    IntraBMode_BRdPred,  /* southeast (right and down) "" */
    IntraBMode_BVrPred,  /* SSE (vertical right) diagonal prediction */
    IntraBMode_BVlPred,  /* SSW (vertical left) "" */
    IntraBMode_BHdPred,  /* ESE (horizontal down) "" */
    IntraBMode_BHuPred   /* ENE (horizontal up) "" */
  } IntraBMode;

  typedef IntraBMode [4-1:0][4-1:0] SubModes;

  typedef struct packed {
    logic       valid;
    logic       mb_skip_coeff;
    IntraMBMode intra_y_mode;
    SubModes    sub_modes;
    IntraMBMode intra_uv_mode;
  } Header;

  localparam byte unsigned KF_YMODE_PROB[0:4-1] = '{145, 156, 163, 128};
  localparam byte unsigned KF_UV_MODE_PROB[0:3-1] = '{142, 114, 183};

  // Trees are represented as flat arrays
  // postive values are offsets to the next node
  // negative values are the leaf values (modes)
  // we use 8 bits signed integers
  localparam byte signed KF_YMODE_TREE[0:8-1] = '{
      -(signed'(byte'(IntraMBMode_BPred))),
      2,
      4,
      6,
      -(signed'(byte'(IntraMBMode_DcPred))),
      -(signed'(byte'(IntraMBMode_VPred))),
      -(signed'(byte'(IntraMBMode_HPred))),
      -(signed'(byte'(IntraMBMode_TmPred)))
  };

  localparam byte signed UV_MODE_TREE[0:6-1] = '{
      -(signed'(byte'(IntraMBMode_DcPred))),
      2,
      -(signed'(byte'(IntraMBMode_VPred))),
      4,
      -(signed'(byte'(IntraMBMode_HPred))),
      -(signed'(byte'(IntraMBMode_TmPred)))
  };

  localparam byte signed BMODE_TREE[0:18-1] = '{
      -(signed'(byte'(IntraBMode_BDcPred))),
      2,
      -(signed'(byte'(IntraBMode_BTmPred))),
      4,
      -(signed'(byte'(IntraBMode_BVePred))),
      6,
      8,
      12,
      -(signed'(byte'(IntraBMode_BHePred))),
      10,
      -(signed'(byte'(IntraBMode_BRdPred))),
      -(signed'(byte'(IntraBMode_BVrPred))),
      -(signed'(byte'(IntraBMode_BLdPred))),
      14,
      -(signed'(byte'(IntraBMode_BVlPred))),
      16,
      -(signed'(byte'(IntraBMode_BHdPred))),
      -(signed'(byte'(IntraBMode_BHuPred)))
  };

endpackage
