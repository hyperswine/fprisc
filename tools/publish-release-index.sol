# Add published GitHub releases to the signed fprmeta/qosmeta indexes.
# The fpr-release private key stays on this machine and is only passed to ssh-keygen.
#
#   fpr sol tools/publish-release-index.sol --tap /path/to/homebrew-tap --key /path/to/fpr-release \
#     fprisc:0.14.0 fprisc:0.15.0 qos:0.5.0 qos:0.6.0
C = use "publish-release-index-core".
main : unsafe Unit -> Unit .
main u = C.cli (args Unit).
> main Unit.
