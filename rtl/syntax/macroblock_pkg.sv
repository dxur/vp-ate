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

  localparam logic [7:0] KF_YMODE_PROB[0:4-1] = '{145, 156, 163, 128};
  localparam logic [7:0] KF_UV_MODE_PROB[0:3-1] = '{142, 114, 183};

  // Trees are represented as flat arrays
  // postive values are offsets to the next node
  // negative values are the leaf values (modes)
  // we use 8 bits signed integers
  localparam logic signed [7:0] KF_YMODE_TREE[0:8-1] = '{
      -(signed'(8'(IntraMBMode_BPred))),
      2,
      4,
      6,
      -(signed'(8'(IntraMBMode_DcPred))),
      -(signed'(8'(IntraMBMode_VPred))),
      -(signed'(8'(IntraMBMode_HPred))),
      -(signed'(8'(IntraMBMode_TmPred)))
  };

  localparam logic signed [7:0] UV_MODE_TREE[0:6-1] = '{
      -(signed'(8'(IntraMBMode_DcPred))),
      2,
      -(signed'(8'(IntraMBMode_VPred))),
      4,
      -(signed'(8'(IntraMBMode_HPred))),
      -(signed'(8'(IntraMBMode_TmPred)))
  };

  localparam logic signed [7:0] BMODE_TREE[0:18-1] = '{
      -(signed'(8'(IntraBMode_BDcPred))),
      2,
      -(signed'(8'(IntraBMode_BTmPred))),
      4,
      -(signed'(8'(IntraBMode_BVePred))),
      6,
      8,
      12,
      -(signed'(8'(IntraBMode_BHePred))),
      10,
      -(signed'(8'(IntraBMode_BRdPred))),
      -(signed'(8'(IntraBMode_BVrPred))),
      -(signed'(8'(IntraBMode_BLdPred))),
      14,
      -(signed'(8'(IntraBMode_BVlPred))),
      16,
      -(signed'(8'(IntraBMode_BHdPred))),
      -(signed'(8'(IntraBMode_BHuPred)))
  };

endpackage
