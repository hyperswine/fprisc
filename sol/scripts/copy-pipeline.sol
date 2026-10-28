# A byte pipeline with a staged no-clobber destination. No shell parsing.
# fpr sol sol/scripts/copy-pipeline.sol SOURCE DESTINATION
report r = case r of
  Err e -> error (str e)
| Ok (PipelineResult 0 statuses bytes errors) -> log "pipeline copy complete"
| Ok (PipelineResult code statuses bytes errors) -> error "pipeline exited {code}: {statuses}".
main = case args Unit of
  [source,target] -> report (Proc.pipeline (PipelineSpec
    [ProcessSpec ["/bin/cat"] "" [] "" 0]
    (PipeFile source) (PipePublish target False) (PipeCapture 4096) 30000 PipeFail))
| _ -> error "usage: copy-pipeline.sol SOURCE DESTINATION".
