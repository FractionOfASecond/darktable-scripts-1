dt = require "darktable"

local _debug = false
local _copy_import_dry_run = false

local ffmpeg_path = None --updated in preferences registration section below
local exiftool_path = None
local ffmpeg_available = false

-------- Constants --------

local exif_date_pattern = "^(%d+):(%d+):(%d+) (%d+):(%d+):(%d+)"
local audioF = "libfaac"
local audioQ = "192k"
local videoContainer = "m4v"
local avchdPattern = "AVCHD-${year}${month}${day}-${hour}${minute}${name}."..videoContainer

--https://www.darktable.org/usermanual/ch02s03.html.php#supported_file_formats
local supported_image_formats_init = {"3FR", "ARW", "BAY", "BMQ", "CAP", "CINE",
"CR2", "CRW", "CS1", "DC2", "DCR", "DNG", "ERF", "FFF", "EXR", "IA", "IIQ",
"JPEG", "JPG", "K25", "KC2", "KDC", "MDC", "MEF", "MOS", "MRW", "NEF", "NRW",
"ORF", "PEF", "PFM", "PNG", "PXN", "QTK", "RAF", "RAW", "RDC", "RW1", "RW2",
"SR2", "SRF", "SRW", "STI", "TIF", "TIFF", "X3F"}
for k,v in pairs({"JP2", "J2K", "JPF", "JPX", "JPM", "MJ2"}) do supported_image_formats_init[k] = v end

local copied_video_formats_init = {"MP4", "M4V", "AVI", "MOV", "3GP"}
local converted_video_formats_init = {"MTS"}

-------- Configuration --------

local mount_root = "/Volumes"
local alternate_inbox_name = "Inbox"
local dcimPath = "/*/DCIM/*/*.*"
local avchd_stream_path = "/*/PRIVATE/AVCHD/BDMV/STREAM/*.MTS"
local alternate_dests = {
  --nil = using the preference setting for folder structure
  --{"/Users/ThePhotographer/Pictures/Darktable", nil},
  
  --folder structure setting overridden for this destination:
  --{"/Users/ThePhotographer/Pictures/Darktable specials", "${year}/${month}"},
}

local using_multiple_dests = (#alternate_dests > 0)

local supported_image_formats = {}
for index,ext in pairs(supported_image_formats_init) do
  supported_image_formats[ext] = true
end

local copied_video_formats = {}
for index,ext in pairs(copied_video_formats_init) do
  copied_video_formats[ext] = true
end

local converted_video_formats = {}
for index,ext in pairs(converted_video_formats_init) do
  converted_video_formats[ext] = true
end

-------- Support functions --------

local function debug_print(message)
  if _debug then
    print(message)
  end
end

local function interp(s, tab)
  local sstring = (s:gsub('($%b{})', function(w) return tab[w:sub(3, -2)] or w end))
  if (string.find(sstring, "${")) then
    dt.print (s.." contains an unsupported variable. Remove it, try again!")
    error()
  end
  
  return sstring
end
getmetatable("").__mod = interp

local function escape_path(path)
  return string.gsub(path, " ", "\\ ")
end

local function split_path(path)
  return string.match(path, "(.-)([^\\/]-%.?([^%.\\/]*))$")
end

function file_exists(path)
  local testIsFileCommand = "test -s "..path
  local testIsNotFileCommand = "test ! -s "..path
  
  local positiveTest = os.execute(testIsFileCommand)
  local negativeTest = os.execute(testIsNotFileCommand)
  
  assert(positiveTest ~= negativeTest)
  
  return (positiveTest ~= nil)
end

local function on_same_volume(absPathA, absPathB)
  local mountedVolumePattern = "^"..mount_root.."/(.-)/"
  
  local rootA = string.match(absPathA, mountedVolumePattern)
  if (rootA == nil) then
    rootA = absPathA:sub(1,1)
    assert(rootA == "/")
  end
  
  local rootB = string.match(absPathB, mountedVolumePattern)
  if (rootB == nil) then
    rootB = absPathB:sub(1,1)
    assert(rootB == "/")
  end
  
  local isSameVolume = (rootA == rootB)
  return isSameVolume
end

-------- import_transaction class --------

local import_transaction = {
  type = nil,
  srcPath = nil,
  destRoot = nil,
  destStructure = nil,
  destPath = nil,
  date = nil,
  tags = nil,
  destFileExists = nil
}

import_transaction.__index = import_transaction

function import_transaction.new(path, destRoot)
  local self = setmetatable({}, import_transaction)
  self.srcPath = path
  self.destRoot = destRoot
  
  assert(self.srcPath ~= "")
  assert(self.destRoot ~= "")
  return self
end

function import_transaction.load(self)
  --check if supported image file or movie, set self.type to 'image' or
  --'movie' or 'none' otherwise
  assert(self.srcPath ~=nil)
  assert(self.destRoot ~= nil)
  local dir, name, ext = split_path(self.srcPath)
  
  
  if (ext ~= nil and supported_image_formats[ext:upper()] == true) then
    self.type = 'image'
  elseif _copy_import_video_enabled == true then
    if (ext ~= nil and converted_video_formats[ext:upper()] == true) then
      assert(ffmpeg_available)
      self.type = 'raw_video'
    elseif (ext ~= nil and copied_video_formats[ext:upper()] == true) then
      self.type = 'video'
    end
  end
  
  if self.type ~= nil then
    self.tags = {}
    
    local exifProc = io.popen(exiftool_path.." -n -s -Time:all '"..self.srcPath.."'")
    for exifLine in exifProc:lines() do
      local tag, value = string.match(exifLine, "([%a ]-)%s+: (.-)$")
      if (tag ~= nil) then
        self.tags[tag] = value
      end
    end
    exifProc:close()
    
    local exifDateTag = self.tags['DateTimeOriginal']
    if (exifDateTag == nil) then
      exifDateTag = self.tags['CreateDate']
    end
    if (exifDateTag == nil) then
      exifDateTag = self.tags['ModifyDate']
    end
    if (exifDateTag == nil) then
      exifDateTag = self.tags['FileModifyDate']
    end
    assert (exifDateTag ~= nil)
    
    local date = {}
    date['year'], date['month'], date['day'], date['hour'], date['minute'], date['seconds']
      = exifDateTag:match(exif_date_pattern)
    self.date = date
    
    local dirStructure = self.destStructure

    if (dirStructure == nil) then
      assert(not using_multiple_dests)
      dirStructure = _copy_import_default_folder_structure
    end
        
    local subst = {}
    for k,v in pairs(self.date) do
      subst[k] = v
    end
    subst['name'] = name
    
    self.destPath = interp(self.destRoot.."/"..dirStructure, subst)
  end
end

function import_transaction.transfer_media(self)
  assert (self.destPath ~= nil)
  assert (self.tags ~= nil)
  assert (self.date ~= nil)
  
  local destDir,_,_ = split_path(self.destPath)
  
  local makeDirCommand = "mkdir -p '"..destDir.."'"
  
  self.destFileExists = file_exists("'"..self.destPath.."'")

  if (self.destFileExists == false) then    
    if _copy_import_dry_run then
      print (makeDirCommand)
    else
      local makeDirSuccess = os.execute(makeDirCommand)
      assert(makeDirSuccess == true)
    end
    
    if self.type == 'raw_video' then
      assert (self.date ~= nil)
      convertCommand = ffmpeg_path.." -i '"..self.srcPath.."' -acodec "..audioF.." -ab "..audioQ.." -vcodec copy '"..self.destPath.."'"
      debug_print("Converting '"..self.srcPath.."' to '"..self.destPath.."'")
      if _copy_import_dry_run == true then
        print (convertCommand)
      else
        local conversionSuccess = os.execute(convertCommand)
        assert(conversionSuccess == true)
      end
      
      --adjust file date attributes
      local datestring = self.date['year']..self.date['month']..self.date['day']..self.date['hour']..self.date['minute'].."."..self.date['seconds']
      local touchCommand = "touch -c -mt "..datestring.." '"..self.destPath.."'"
      if _copy_import_dry_run then
        print (touchCommand)
      else
        local touchSuccess = os.execute(touchCommand)
        assert(touchSuccess == true)
      end
    else
      assert (self.type == 'image' or self.type == 'video')
      local copyMoveCommand = "cp -n '"..self.srcPath.."' '"..self.destPath.."'"
      if (on_same_volume(self.srcPath,self.destPath)) then
        copyMoveCommand = "mv -n '"..self.srcPath.."' '"..self.destPath.."'"
        debug_print("Moving '"..self.srcPath.."' to '"..self.destPath.."'")
      else
        debug_print("Copying '"..self.srcPath.."' to '"..self.destPath.."'")
      end
      
      if _copy_import_dry_run == true then
        print (copyCommand)
      else
        local copyMoveSuccess = os.execute(copyMoveCommand)
        assert(copyMoveSuccess == true)
      end
    end
  else
    destDir = nil
  end
  
  self.destFileExists = file_exists("'"..self.destPath.."'")
  assert(self.destFileExists == true)
  
  return destDir
end

-------- Subroutines --------

local function scrape_files(scrapePattern, destRoot, structure, list)
  local numFilesFound = 0
  debug_print ("Scraping "..scrapePattern.." to "..destRoot)

  for imagePath in io.popen("ls "..scrapePattern):lines() do
    local trans = import_transaction.new(imagePath, destRoot)
    trans.destStructure = structure
    
    table.insert(list, trans)
    numFilesFound = numFilesFound + 1
  end
  
  return numFilesFound
end

-------- Main function --------

local function _copy_import_main()
  local stats = {}
  
  stats['numImagesFound'] = 0
  stats['numVideosFound'] = 0
  stats['numFilesDuplicate'] = 0
  stats['numFilesFound'] = 0
  stats['numFilesProcessed'] = 0
  stats['numFilesScanned'] = 0
  stats['numUnsupportedFound'] = 0
  
  exiftool_path = dt.preferences.read("copy_import", "ExifToolPath", "file")
  ffmpeg_path = dt.preferences.read("copy_import", "FFMPEGPath", "file")

  ffmpeg_available = (os.execute(ffmpeg_path.." -h") ~= nil)

  if (os.execute(exiftool_path.." -ver") == nil) then
    dt.print("Could not find ExifTool at "..exiftool_path)
    return
  end
  
  local dcimDestRoot = nil
  local video_separate_dest = nil

  if(using_multiple_dests) then
    dcimDestRoot = dt.preferences.read("copy_import","DCFImportDirectorySelect", "enum")
    video_separate_dest = true
  else
    dcimDestRoot = dt.preferences.read("copy_import","DCFImportDirectoryBrowse","directory")
    video_separate_dest = not dt.preferences.read("copy_import","VideoImportCombined", "bool")
  end
  
  _copy_import_video_enabled = dt.preferences.read("copy_import","VideoImportEnabled", "bool")
  local videoDestRoot = dcimDestRoot
  local video_folder_structure = nil
  
  _copy_import_default_folder_structure = dt.preferences.read("copy_import","FolderPattern", "string")

  if using_multiple_dests then
    videoDestRoot = dt.preferences.read("copy_import","VideoImportDirectorySelect","enum")
    for _, altConf in pairs(alternate_dests) do
      local dir = altConf[1]
      if dir == videoDestRoot then
        video_folder_structure = altConf[2]
        break
      end
    end
  elseif video_separate_dest then
    videoDestRoot = dt.preferences.read("copy_import","VideoImportDirectoryBrowse","directory")
    video_folder_structure = dt.preferences.read("copy_import","VideoFolderPattern", "string")
  end
  assert (video_folder_structure ~= nil)
  
  transactions = {}
  changedDirs = {}
  
  local testDestRootMounted = "test -d '"..dcimDestRoot.."'"
  local destMounted = os.execute(testDestRootMounted)
  
  --Handle DCF (flash card) import
  
  local videoDestMounted = false
  if _copy_import_video_enabled then
    local testVideoDestRootMounted = "test -d '"..videoDestRoot.."'"
    videoDestMounted = os.execute(testVideoDestRootMounted)
  end
  
  if destMounted == true and (not _copy_import_video_enabled or videoDestMounted) then
    stats['numFilesFound'] = stats['numFilesFound'] +
      scrape_files(escape_path(mount_root)..dcimPath, dcimDestRoot, _copy_import_default_folder_structure.."/${name}", transactions)
    
    if _copy_import_video_enabled == true then 
      if video_separate_dest == true then
          stats['numFilesFound'] = stats['numFilesFound'] +
            scrape_files(escape_path(mount_root)..avchd_stream_path, videoDestRoot, video_folder_structure.."/"..avchdPattern, transactions)
      else
        stats['numFilesFound'] = stats['numFilesFound'] +
          scrape_files(escape_path(mount_root)..avchd_stream_path, dcimDestRoot, _copy_import_default_folder_structure.."/"..avchdPattern, transactions)
      end
    end
  else
    dt.print(dcimDestRoot.." is not mounted. Memory card contents will not be imported.")
  end

  --Handle user sorted 'inbox' import
  for _, altConf in pairs(alternate_dests) do
    local dir = altConf[1]
    local dirStructure = altConf[2]
    
    local testAltDirExists = "test -d '"..dir.."'"
    local altDirExists = os.execute(testAltDirExists)
    if (altDirExists == true) then
      local ensureInboxExistsSuccess = os.execute("mkdir -p '"..dir.."/"..alternate_inbox_name.."'")
      assert(ensureInboxExistsSuccess == true)

      --Note: without any wildcard * in path, ls will list filenames only, wihout full path
      stats['numFilesFound'] = stats['numFilesFound'] +
        scrape_files(escape_path(dir).."/"..escape_path(alternate_inbox_name).."/*", dir, dirStructure.."/${name}", transactions)
    else
      dt.print(dir.." could not be found and was skipped over.")
    end
  end
  
  --Read image metadata and copy/move
  local copy_progress_job = dt.gui.create_job ("Copying/moving media", true)
  
  --Separate loop for load, so that, in case of error, copying/moving the images
  --will not fail halfway through
  for _,tr in pairs(transactions) do
    tr:load()
    
    stats['numFilesScanned'] = stats['numFilesScanned'] + 1
    copy_progress_job.percent = (stats['numFilesScanned']*0.5) / stats['numFilesFound']
  end
  
  for _,tr in pairs(transactions) do
    if tr.type ~= nil then
      if tr.type == 'image' then
        stats['numImagesFound'] = stats['numImagesFound'] + 1
      elseif tr.type == 'video' or tr.type == 'raw_video' then
        stats['numVideosFound'] = stats['numVideosFound'] + 1
      else
        stats['numUnsupportedFound'] = stats['numUnsupportedFound'] + 1
      end
      local destDir = tr:transfer_media()
      if (destDir ~= nil) then
        changedDirs[destDir] = true
        stats['numFilesProcessed'] = stats['numFilesProcessed'] + 1
      else
        stats['numFilesDuplicate'] = stats['numFilesDuplicate'] + 1
      end
    end
    copy_progress_job.percent = 0.5 + ((stats['numFilesProcessed'] + stats['numFilesDuplicate'])*0.5) / stats['numFilesFound']
  end
  
  copy_progress_job.valid = false
  
  --Tell Darktable to import images
  for dir,_ in pairs(changedDirs) do
    dt.database.import(dir)
  end
  
  --Build completion user message and display it
  if (stats['numFilesFound'] > 0) then
    assert(stats ['numFilesFound'] == stats['numFilesProcessed'] + stats['numFilesDuplicate'] + stats['numUnsupportedFound'])
    assert(stats['numUnsupportedFound'] == stats['numFilesFound'] - stats['numImagesFound'] - stats['numVideosFound'])
    
    local completionMessage = ""
    if (stats['numImagesFound'] > 0) then
      completionMessage = stats['numImagesFound'].." images"
      if _copy_import_video_enabled == true then
        completionMessage = completionMessage..", "..stats['numVideosFound'].." videos"
      end
      completionMessage = completionMessage.." imported."
      if (stats['numFilesDuplicate'] > 0) then
        completionMessage = completionMessage.." "..stats['numFilesDuplicate'].." duplicates were ignored."
      end
    end
    
    if stats['numUnsupportedFound'] > 0 then
      completionMessage = completionMessage.." "..stats['numUnsupportedFound'].." unsupported files were ignored."
    end
    dt.print(completionMessage)
  else
    dt.print("No files found. Is your memory card not mounted, or empty?")
  end
end

-------- Error handling wrapper --------

function copy_import_handler()
  if (_debug) then
    --Do a regular call, which will output complete error traceback to console
    _copy_import_main()
  else
    
    local main_success, main_error = pcall(_copy_import_main)
    if (not main_success) then
      --Do two print calls, in case tostring conversion fails, user will still see a message
      dt.print("An error prevented Copy import script from completing")
      dt.print("An error prevented Copy import script from completing: "..tostring(main_error))
    end
  end
end

-------- Preferences registration --------

local alternate_dests_paths = {}
for _,conf in pairs(alternate_dests) do
  table.insert(alternate_dests_paths, conf[1])
end

dt.preferences.register("copy_import", "FFMPEGPath", "file", "Copy import: Location of FFMPEG tool (needed for video conversion)", "help", "/opt/local/bin/ffmpeg" )

dt.preferences.register("copy_import", "ExifToolPath", "file", "Copy import: Location of ExifTool (required)", "help", "/usr/local/bin/exiftool" )

if(using_multiple_dests) then
  dt.preferences.register("copy_import", "DCFImportDirectorySelect", "enum", "Copy import: which of the destination folders to import mounted flash memories (DCF) to", "Select which folder (from your own multi-import list) that will be used for importing directly from mounted camera flash storage.", alternate_dests_paths[1], unpack(alternate_dests_paths) )
  dt.preferences.register("copy_import", "VideoImportDirectorySelect", "enum", "Copy import: separate video import destination (if not stored together with photos)", "Select which folder (from your own multi-import list) that will be used for importing directly from mounted camera flash storage.", alternate_dests_paths[1], unpack(alternate_dests_paths) )
else
  dt.preferences.register("copy_import", "DCFImportDirectoryBrowse", "directory", "Copy import: root folder to import to (photo library)", "Choose the folder that will be used for importing directly from mounted camera flash storage.", "/" )
  dt.preferences.register("copy_import", "FolderPattern", "string", "Copy import: default folder naming structure for imports", "Create a folder structure within the import destination folder. Available variables: ${year}, ${month}, ${day}. Original filename is appended at the end.", "${year}/${month}/${day}" )
  dt.preferences.register("copy_import", "VideoImportDirectoryBrowse", "directory", "Copy import: Separate video import destination (if not stored together with photos)", "", "~/Movies" )
  dt.preferences.register("copy_import", "VideoFolderPattern", "string", "Copy import: Separate video folder pattern", "", "${year}/${month}/${day}" )
  dt.preferences.register("copy_import", "VideoImportCombined", "bool", "Copy import: Import video to same location as photos", "", false )
end

dt.preferences.register("copy_import", "VideoImportEnabled", "bool", "Copy import: import video", "", false )

-------- Event registration --------

dt.register_event("shortcut", copy_import_handler, "Copy and import images from memory cards and '"..alternate_inbox_name.."' folders")