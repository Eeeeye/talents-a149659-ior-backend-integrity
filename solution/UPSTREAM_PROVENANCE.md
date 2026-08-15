# Reference-repair provenance

The Starter is public IOR commit:

- `b98f10f79831cd073b63af4f10866c1c7f40c07c`, 2024-12-13
- <https://github.com/hpc/ior/commit/b98f10f79831cd073b63af4f10866c1c7f40c07c>

The reference patch is the clean composition, on that exact base, of four
public upstream repairs:

1. `e79e76e415ec5475b91728eb77a662a0d31cb9a8` — remove an AIO diagnostic
   print and initialize MPI before rank-filtered option output (PR 493).
2. `144c5ff49a05de4bfc4c990ca25b1f440e9b7c5e` — repair JSON summary framing
   and suppress non-document output in JSON mode (PR 504).
3. `bd70d54e2bf9ad4f76f1eb9a5734014fdf49e40e` — correct MPI-IO basic-element
   byte accounting (PR 515).
4. `8934d0d176f2ef332624bf80a3366430385d88ad` — repair Linux AIO shared-buffer
   races and premature verification (PR 533).

Upstream repository: <https://github.com/hpc/ior>

The source and modifications remain under the GNU General Public License,
version 2, as stated by the retained `COPYRIGHT` file and source headers.

No private incident material, credentials, customer identifiers, or restricted
code is included. The terminal symptoms are reproduced solely from the public
source history with local MPI ranks and local files.
