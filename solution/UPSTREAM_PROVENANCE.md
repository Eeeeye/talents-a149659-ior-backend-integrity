# Reference-repair provenance

The Starter is public IOR commit:

- `b98f10f79831cd073b63af4f10866c1c7f40c07c`, 2024-12-13
- <https://github.com/hpc/ior/commit/b98f10f79831cd073b63af4f10866c1c7f40c07c>

The reference patch is built on that exact base from the following public
upstream repairs:

1. `e79e76e415ec5475b91728eb77a662a0d31cb9a8` — remove an AIO diagnostic
   print and initialize MPI before rank-filtered option output (PR 493).
2. `144c5ff49a05de4bfc4c990ca25b1f440e9b7c5e` — repair JSON summary framing
   and suppress non-document output in JSON mode (PR 504).
3. `bd70d54e2bf9ad4f76f1eb9a5734014fdf49e40e` — correct MPI-IO basic-element
   byte accounting (PR 515).
4. `8934d0d176f2ef332624bf80a3366430385d88ad` — repair Linux AIO shared-buffer
   races and premature verification (PR 533).
5. `0d4a6c5` and `5c54511b096e6563c5c1528cd9ba89bb3cfd8b93`
   — add repeated-`-Z` shuffle mode and correct its rank-offset calculation
   (issues 500 and 512).

The author-side reference additionally completes standards-defined boundary
handling that the public base exposes: RFC 8259 escaping for runtime string
values, partial and interrupted libaio calls, and explicit validation of the
two libaio completion result fields. These changes are derived solely from the
public IOR source plus the public JSON and libaio interfaces; they introduce no
private code or incident material.

Upstream repository: <https://github.com/hpc/ior>

The source and modifications remain under the GNU General Public License,
version 2, as stated by the retained `COPYRIGHT` file and source headers.

No private incident material, credentials, customer identifiers, or restricted
code is included. The terminal symptoms are reproduced solely from the public
source history with local MPI ranks and local files.
