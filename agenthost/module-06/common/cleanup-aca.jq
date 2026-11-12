def check($ok; $message): if $ok then . else error($message) end;
def token: type=="string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$");
def refs($object; $id): [$object|..|strings|select(.==$id)]|length>0;
def source_refs($object; $id):
  [$object|del(.labels)|paths(strings) as $path |
    select(any($path[]; type=="string" and test("source|sandbox|disk|snapshot";"i"))) |
    getpath($path)|select(.==$id)]|length>0;
check(all([$sandboxes,$disks,$snapshots,$volumes][]; type=="array"); "Expected ACA arrays") |
check(all(($sandboxes+$disks+$snapshots)[]; .id|token); "Invalid ACA ID") |
check(all($sandboxes[]; .sourcesRef|type=="object"); "Sandbox source references missing") |
check(all($volumes[];
  ((.volumeName // .name)|token) and (.type|type=="string") and
  (if .type=="AzureBlobByo" then (.storageContainerResourceId|type=="string") else true end));
  "Malformed volume list") |
[$inventories[]|.deployment_id] as $deployments |
[$inventories[]| .deployment_id as $deployment |
  .agents|to_entries[]|.key as $role|.value as $record|
  [$disks[]|select(.labels.deployment==$deployment and .labels.role==$role)] as $owned_disks |
  [$sandboxes[]|select(.labels.deployment==$deployment and .labels.role==$role)] as $owned_sandboxes |
  check(($owned_disks|length)<=1 and ($owned_sandboxes|length)<=1; "Ambiguous deployment/role") |
  check(all($disks[]|select(.id==$record.disk_id); .labels.deployment==$deployment and .labels.role==$role);
    "Recorded disk ownership mismatch") |
  check(all($sandboxes[]|select(.id==$record.sandbox_id); .labels.deployment==$deployment and .labels.role==$role);
    "Recorded sandbox ownership mismatch") |
  check(all($owned_disks[]; $record.disk_id==null or .id==$record.disk_id); "Recorded disk ID mismatch") |
  ($record.disk_id // $owned_disks[0].id) as $disk |
  check(all($owned_sandboxes[];
    ($record.sandbox_id==null or .id==$record.sandbox_id) and $disk!=null and .sourcesRef.diskImage.id==$disk);
    "Sandbox ID/source mismatch") |
  {sandboxes:[$owned_sandboxes[].id],disks:[$owned_disks[].id]}
] as $roles |
([$roles[].sandboxes[]]|unique) as $sandbox_ids |
([$roles[].disks[]]|unique) as $disk_ids |
check(all(($sandboxes+$disks+$snapshots)[]|select(.labels.deployment as $d|$deployments|index($d));
  .labels.role as $r|["chat","orchestrator","data-processing","rag","sql"]|index($r));
  "Unknown Module-06 role") |
([$sandbox_ids[],$disk_ids[],
  ($inventories[].agents[]|.sandbox_id // empty),
  ($inventories[].agents[]|.disk_id // empty)]|unique) as $origins |
([$snapshots[]|select(.labels.deployment as $d|$deployments|index($d))|.id]) |
until(. as $known |
    all($snapshots[]; . as $s |
      if any(($origins+$known)[]; source_refs($s; .)) then ($known|index($s.id))!=null else true end);
  . as $known |
  (.+[$snapshots[]|. as $s|select(any(($origins+$known)[]; source_refs($s; .)))|.id]|unique)
) as $snapshot_ids |
check(all($snapshots[]|select(.id as $id|$snapshot_ids|index($id));
  (.labels.module==null or .labels.module=="module-06") and
  (.labels.deployment==null or (.labels.deployment as $d|$deployments|index($d)!=null)));
  "Snapshot source and ownership labels conflict") |
check(all($sandboxes[]|select(.id as $id|$sandbox_ids|index($id)|not);
  . as $s|all(($disk_ids+$snapshot_ids)[]; refs($s; .)|not));
  "Disk/snapshot used by an unrelated sandbox") |
[$inventories[].volume // empty]|unique_by(.name) as $volume_records |
check(all($volume_records[];
  (.name|token) and .type=="AzureBlobByo" and
  (.storage_container_id|test("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Storage/storageAccounts/[a-z0-9]{3,24}/blobServices/default/containers/data$")));
  "Invalid Module-06 data volume record") |
check(all($inventories[].volume // empty;
  . as $v | all($volume_records[]|select(.name==$v.name); .storage_container_id==$v.storage_container_id));
  "Conflicting saved volume containers") |
check(all($volume_records[];
  . as $v |
  all($volumes[]|select((.volumeName // .name)==$v.name);
    .type=="AzureBlobByo" and .storageContainerResourceId==$v.storage_container_id and
    .auth.kind=="ManagedIdentity" and .auth.identity.kind==$v.identity_kind and
    (if $v.identity_kind=="UserAssigned" then .auth.identity.resourceId==$v.identity else true end)));
  "Live volume differs from recorded Module-06 volume") |
check(all($sandboxes[]|select(.id as $id|$sandbox_ids|index($id)|not);
  . as $s|all($volume_records[].name; refs($s; .)|not));
  "Module-06 volume used by an unrelated sandbox") |
check(all($volumes[];
  . as $v | all($volume_records[];
    if .storage_container_id==$v.storageContainerResourceId then
      any($volume_records[]; .name==($v.volumeName // $v.name)) else true end));
  "Data container is referenced by another volume") |
{sandboxes:$sandbox_ids,snapshots:($snapshot_ids|sort),disks:$disk_ids,
 volumes:([$volumes[]|(.volumeName // .name) as $n|select(any($volume_records[]; .name==$n))|$n]|unique),
 containers:([$volume_records[].storage_container_id]|unique),
 unattributed_snapshots:([$snapshots[].id]-$snapshot_ids|sort)}
