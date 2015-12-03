% pRF.m
%
%        $Id:$ 
%      usage: pRF(v,params,varargin)
%         by: justin gardner
%       date: 11/20/11
%    purpose: compute pRF analysis on MLR data
%
%             if you just want a default parameter structure you
%             can do:
% 
%             v = newView;
%             [v params] = pRF(v,[],'justGetParams=1','defaultParams=1','scanList=1')
%
%             Note that justGetParams,defualtParams and scanList are independent parameters, so
%             if you want, say to bring up the GUI to set the params, but not run the analysis, you
%             can do:
%             [v params] = pRF(v,[],'justGetParams=1');
%
function [v d] = pRF(v,params,varargin)

% check arguments
if nargin < 1
  help pRF
  return
end

d = [];
% a version number in case we make major changes
pRFVersion = 2;

% params defaults to empty
if nargin < 2,params =[];end

% other arguments
justGetParams=[];defaultParams=[];scanList=[];
groupNum=[];
getArgs(varargin,{'justGetParams=0','defaultParams=0','scanList=[]','groupNum=[]'});

% first get parameters
if isempty(params)
  % get group
  if isempty(groupNum),groupNum = viewGet(v,'curGroup');end
  % put up the gui
  params = pRFGUI('v',v,'groupNum',groupNum,'defaultParams',defaultParams,'scanList',scanList);
end

% just return parameters
if justGetParams,d = params;return,end

% Reconcile params with current status of group and ensure that it has
% the required fields. 
params = defaultReconcileParams([],params);

% Abort if params empty
if isempty(params),return,end

% check the params
params = checkPRFparams(params);

% set the group
v = viewSet(v,'curGroup',params.groupName);

% get number of workers 
nProcessors = mlrNumWorkers;

% create a default overlay
dateString = datestr(now);
defaultOverlay.groupName = params.groupName;
defaultOverlay.function = 'pRF';
defaultOverlay.reconcileFunction = 'defaultReconcileParams';
defaultOverlay.data = cell(1,viewGet(v,'nScans'));
defaultOverlay.date = dateString;
defaultOverlay.params = cell(1,viewGet(v,'nScans'));
defaultOverlay.interrogator = 'pRFPlot';
defaultOverlay.mergeFunction = 'pRFMergeParams';

% initialize the model - this primarily should set the overlay parameters
global gPRFModels;
[params.fitParams overlays] = feval(gPRFModels(params.fitParams.modelNum).initFit,params.fitParams,defaultOverlay);

% check for some fields that should have been set
fieldCheck = {'nParams','paramNames'};
fields = fieldnames(params.fitParams);
missingFields = setdiff(fieldCheck,fields);
if ~isempty(missingFields)
  mrWarnDlg(sprintf('(pRF) The following fields need to be set in initFit function for model: %s',params.fitParams.rfType));
  for iField = 1:length(missingFields)
    disp(sprintf('   ** %s **',missingFields{iField}));
  end
  keyboard
end

% count overlays added and make sure we have 
% which parameter they go with
if ~isempty(overlays)
  nOverlays = length(fieldnames(overlays));
  if ~isfield(params.fitParams,'overlayParamNum') || ~isequal(length(params.fitParams.overlayParamNum),nOverlays)
    disp(sprintf('(pRF) initFit for %s has to set overlayParamNum to an array that tells which parameter number corresponds with which overlay',params.fitParams.rfType));
    keyboard
  end
end

% add an overlay for r2
overlays.r2 = defaultOverlay;
overlays.r2.name = 'r2';
overlays.r2.range = [0 1];
overlays.r2.clip = [0 1];
% colormap is made with a little bit less on the dark end
overlays.r2.colormap = hot(312);
overlays.r2.colormap = overlays.r2.colormap(end-255:end,:);
overlays.r2.alpha = 1;
overlays.r2.colormapType = 'setRangeToMax';

dispHeader
disp(sprintf('(pRF) Running on scans %s:%s (restrict %s)',params.groupName,num2str(params.scanNum,'%i '),params.restrict ));

for scanNum = params.scanNum
  % see how long it took
  tic;
  
  % get voxels that we are restricted to
  [x y z] = getVoxelRestriction(v,params,scanNum);
  if isempty(x)
    disp(sprintf('(pRF) No voxels to analyze with current restriction'));
    return
  end

  % get total number of voxels
  n = length(x);

  % get scan dims
  scanDims = viewGet(v,'scanDims',scanNum);
  
  % init overlays
  overlayNames = fieldnames(overlays);
  nOverlays = length(overlayNames);
  for iOverlay = 1:nOverlays
    % initialize the overlay
    overlays.(overlayNames{iOverlay}).data{scanNum} = nan(scanDims);
    % and initialze the overlaysTemp variable which
    % will hold values in the parfor loop
    overlaysTemp.(overlayNames{iOverlay}) = nan(1,n);
  end

  % get concatInfo and other scan related info
  params.fitParams.concatInfo = pRFGetConcatInfo(v,scanNum);
  params.fitParams.framePeriod = viewGet(v,'framePeriod',scanNum);
  params.fitParams.junkFrames = viewGet(v,'junkFrames',scanNum);
  
  % call init function for model to get stim
  [tf cachedVal] = pRFFitGlobalStimAndPrefit(params.fitParams,params.groupName,scanNum);
  if tf
    % get saved one - this saves some time by
    % caching an already computed stim and prefit
    disp(sprintf('(pRF) Using cached stim and prefit (check recomputeStimImageAndPrefit if you want to recompute instead)'));
    params.fitParams = cachedVal;
  else
    % compute the stim
    [params.fitParams params.fitParams.stim] = feval(gPRFModels(params.fitParams.modelNum).getStim,params.fitParams,v,scanNum);

    % check for inability to compute stim
    if isempty(params.fitParams.stim),return,end
    
    % init the scan, (which will return prefit parameters)
    [params.fitParams prefitParams]= feval(gPRFModels(params.fitParams.modelNum).initScan,params.fitParams);
    
    % see if we were passed back prefit parameters
    if ~isempty(prefitParams)
      % check that size is correct
      if size(prefitParams,2) ~= params.fitParams.nParams
	disp(sprintf('(pRF) Prefit parameters should be nxk where n is number of prefit models to compute and k is number of parameters: %i',params.fitParams.nParams));
	keyboard
      end
      % compute prefit
      params.fitParams = computePrefit(params.fitParams,prefitParams);
    end
    % save in global
    pRFFitGlobalStimAndPrefit(params.fitParams,params.groupName,scanNum);
  end

  % see if we should do the prefit. If so, we should have the
  % fields prefit.params and prefit.modelResponse these
  % fields will be used to find the highest correlation with
  % the prefit modelResponse and using those parameters as
  % initial parameters
  doPrefit = false;
  if isfield(params.fitParams,'prefit') && isfield(params.fitParams.prefit,'params')  && isfield(params.fitParams.prefit,'modelResponse')
    doPrefit = true;
  end

  % save pRF parameters
  pRFAnal.d{scanNum}.ver = pRFVersion;
  pRFAnal.d{scanNum}.linearCoords = [];
  pRFAnal.d{scanNum}.params = [];

  % preallocate some space
  rawParams = nan(n,params.fitParams.nParams);
  r = nan(n,params.fitParams.concatInfo.n);

  % get some info about the scan to pass in (which prevents
  % pRFFit from calling viewGet - which is problematic for distributed computing
  framePeriod = viewGet(v,'framePeriod');
  junkFrames = viewGet(v,'junkFrames',scanNum);

  % compute pRF for each voxel in the restriction
  if params.fitParams.prefitOnly,algorithm='prefit-only';else,algorithm=params.fitParams.algorithm;end

  % disp info about fitting
  dispHeader;
  disp(sprintf('(pRF) Scan %s:%i (restrict %s) running on %i processor(s)',params.groupName,scanNum,params.restrict,nProcessors));
  disp(sprintf('(pRF) Computing %s fits using %s for %i voxels',params.fitParams.rfType,algorithm,n));
  dispHeader;

  % this is a bit arbitrary but is the number of voxels to read in at a time.
  % should probably be either calculated based on memory demands or a
  % user settings. The bigger the number the less overhead and will run faster
  % but consume more memory. The overhead is not terribly significant though
  % as tested on my machine - maybe a few percent faster with full n, but
  % on many machines without enough memory that will crash it so keeping
  % this preliminary value in for now.
  blockSize = 240;
  tic;
  % break into blocks of voxels to go easy on memory
  % if blockSize = n then this just does on block at a time.
  for blockStart = 1:blockSize:n

    % display information about what we are doing
    % get blockEnd
    blockEnd = min(blockStart + blockSize-1,n);
    blockSize = blockEnd-blockStart+1;
    
    % load ROI
    loadROI = makeEmptyROI(v,'scanNum',scanNum,'groupNum',params.groupName);
    loadROI.coords(1,1:blockSize) = x(blockStart:blockEnd);
    loadROI.coords(2,1:blockSize) = y(blockStart:blockEnd);
    loadROI.coords(3,1:blockSize) = z(blockStart:blockEnd);
    % load all time series for block, we do this to pass into pRFFit. Generally
    % the purpose here is that if we run on distributed computing, we
    % can't load each voxel's time series one at a time. If this is
    % too large for memory then you can comment this out and not
    % pass it into pRFFit and pRFFit will load the tSeries itself
    loadROI = loadROITSeries(v,loadROI,scanNum,params.groupName);
    % reorder x,y,z coordinates since they can get scrambled in loadROITSeries
    x(blockStart:blockEnd) = loadROI.scanCoords(1,1:blockSize);
    y(blockStart:blockEnd) = loadROI.scanCoords(2,1:blockSize);
    z(blockStart:blockEnd) = loadROI.scanCoords(3,1:blockSize);
    % keep the linear coords
    pRFAnal.d{scanNum}.linearCoords = [pRFAnal.d{scanNum}.linearCoords sub2ind(scanDims,x(blockStart:blockEnd),y(blockStart:blockEnd),z(blockStart:blockEnd))];

    if blockStart ~= 1
      % display time update
      dispHeader(sprintf('(pRF) %0.1f%% done in %s (Estimated time remaining: %s)',100*blockStart/n,mlrDispElapsedTime(toc),mlrDispElapsedTime((toc*n/blockStart) - toc)));
    end

    % now parfor loop over each voxel
    % Fix this to parfor
    for i = blockStart:blockEnd
      % load tSeries
      tSeries = squeeze(loadTSeries(v,scanNum,z(i),[],x(i),y(i)));
      % Normalize tSeries (since we are going to computer r)
      tSeriesNorm = tSeries-mean(tSeries);
      tSeriesNorm = tSeriesNorm/sqrt(sum(tSeriesNorm.^2));
      % do prefit if we have it for getting initial parameters
      initParams = [];
      if doPrefit
	% calculate r for all modelResponse by taking inner product
	prefitr = params.fitParams.prefit.modelResponse*tSeriesNorm;
	[maxr bestModel] = max(prefitr);
	% get the parameters that match that modelResponse
	initParams = params.fitParams.prefit.params(bestModel,:);
      end

      % now run model specific initVoxel which can be used
      % to preprocess tSeries and set initParams
      [params.fitParams tSeries initParams] = feval(gPRFModels(params.fitParams.modelNum).initVoxel,params.fitParams,tSeriesNorm,initParams);
      % now optimize parameters to fit
      % now do nonlinear fit
      if strcmp(lower(params.fitParams.algorithm),'levenberg-marquardt')
	disp(sprintf('!!! Not implemented yet'));
	keyboard
%	[bestParams resnorm residual exitflag output lambda jacobian] = lsqnonlin(@getModelResidual,fitParams.initParams,fitParams.minParams,fitParams.maxParams,fitParams.optimParams,tSeries,fitParams);

      elseif strcmp(lower(params.fitParams.algorithm),'nelder-mead')
	% set optimParams
	optimParams = optimset('MaxIter',inf);
	% run fminsearch
	[best.params best.r exitflag] = fminsearch(@getModelResidual,initParams,optimParams,tSeriesNorm,params.fitParams);
	best.r = 1-best.r;
      else
	disp(sprintf('(pRFFit) Unknown optimization algorithm: %s',fitParams.algorithm));
	return
      end
      if params.fitParams.verbose
	disp(sprintf('%04i/%04i [%i %i %i] params=[%s] r2=%0.3f',i,n,x(i),y(i),z(i),mlrnum2str(best.params),best.r^2));
      end
      % keep parameters
      rawParams(i,:) = best.params(:);
      r(i,:) = best.r;
    end
  end

  % keep best parameters and r value
  pRFAnal.d{scanNum}.params = rawParams;
  pRFAnal.d{scanNum}.r = r;

  % call end scan, to do any last processing on overlays and d
  [overlayParams pRFAnal.d{scanNum}] = feval(gPRFModels(params.fitParams.modelNum).endScan,params.fitParams,rawParams,pRFAnal.d{scanNum});

  % set overlays
  for iVoxel = 1:n
    % set r2 overlay
    overlays.r2.data{scanNum}(x(iVoxel),y(iVoxel),z(iVoxel)) = r(iVoxel,1)^2;
    % set other overlays
    for iOverlay = 1:(nOverlays-1)
      overlays.(overlayNames{iOverlay}).data{scanNum}(x(iVoxel),y(iVoxel),z(iVoxel)) = overlayParams(iVoxel,params.fitParams.overlayParamNum(iOverlay));
    end
  end

  % display time update
  dispHeader;
  disp(sprintf('(pRF) Fitting %i voxels took %s.',n,mlrDispElapsedTime(toc)));
  dispHeader;
  
  iScan = find(params.scanNum == scanNum);
  thisParams.scanNum = params.scanNum(iScan);
  for iOverlay = 1:nOverlays
    overlays.(overlayNames{iOverlay}).params{scanNum} = thisParams;
  end
  
  % display how long it took
  disp(sprintf('(pRF) Fitting for %s:%i took in total: %s',params.groupName,scanNum,mlrDispElapsedTime(toc)));
end

% convert overlays with fields to validated array of overlays
clear o;
for iOverlay = 1:nOverlays
  [tf thisOverlay] = isoverlay(overlays.(overlayNames{iOverlay}));
  if tf
    o(iOverlay) = thisOverlay;
  else
    disp(sprintf('(pRF) Overlay %s is invalid',overlayNames{iOverlay}));
  end
end

% set up analysis
pRFAnal.name = params.saveName;
pRFAnal.type = 'pRFAnal';
pRFAnal.groupName = params.groupName;
pRFAnal.function = 'pRF';
pRFAnal.reconcileFunction = 'defaultReconcileParams';
pRFAnal.mergeFunction = 'pRFMergeParams';
pRFAnal.guiFunction = 'pRFGUI';
pRFAnal.params = params;
pRFAnal.overlays = o;
pRFAnal.curOverlay = 1;
pRFAnal.date = dateString;

% call endFit
pRFAnal = feval(gPRFModels(params.fitParams.modelNum).endFit,params.fitParams,pRFAnal);


v = viewSet(v,'newAnalysis',pRFAnal);

% if we are going to merge, temporarily set overwritePolicy
if isfield(params,'mergeAnalysis') && params.mergeAnalysis
  saveMethod = mrGetPref('overwritePolicy');
  mrSetPref('overwritePolicy','Merge');
end

% save the analysis
saveAnalysis(v,pRFAnal.name);

% now set policy back
if isfield(params,'mergeAnalysis') && params.mergeAnalysis
  mrSetPref('overwritePolicy',saveMethod);
end

% redisplay
if ~isempty(viewGet(v,'fignum'))
  refreshMLRDisplay(viewGet(v,'viewNum'));
end

%set(viewGet(v,'figNum'),'Pointer','arrow');drawnow

% for output
if nargout > 1
  for i = 1:length(d)
    if isfield(overlays,'r2')
      pRFAnal.d{i}.r2 = overlays.r2.data{i};
    else
      pRFAnal.d{i}.r2 = [];
    end
  end
  % make d strucutre
  if length(pRFAnal.d) == 1
    d = pRFAnal.d{1};
  else
    d = pRFAnal.d;
  end
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%    getVoxelRestriction    %
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function [x y z] = getVoxelRestriction(v,params,scanNum)

x = [];y = [];z = [];

if strncmp(params.restrict,'Base: ',6)
  % get the base name
  baseName = params.restrict(7:end);
  baseNums = [];
  if strcmp(baseName,'ALL')
    for iBase = 1:viewGet(v,'numBase')
      % if the base is a surface or flat then add to the list
      if any(viewGet(v,'baseType',iBase) == [1 2])
	baseNums(end+1) = iBase;
      end
    end
  else
    baseNums = viewGet(v,'baseNum',baseName);
  end
  % cycle through all bases that we are going to run on
  scanCoords = [];
  for iBase = 1:length(baseNums)
    % get the baseNum
    baseNum = baseNums(iBase);
    if isempty(baseNum)
      disp(sprintf('(pRF) Could not find base to restrict to: %s',params.restrict));
      continue
    end
    % get the base
    base = viewGet(v,'base',baseNum);
    if isempty(base)
      disp(sprintf('(pRF) Could not find base to restrict to: %s',params.restrict));
      return;
    end
    % if flat or surface
    if any(base.type == [1 2])
      % get base coordinates from the coordMap
      for corticalDepth = 0:0.1:1
	if base.type == 1
	  % flat map
	  baseCoords = (base.coordMap.innerCoords + corticalDepth * (base.coordMap.outerCoords-base.coordMap.innerCoords));
	  baseCoords = reshape(baseCoords,prod(size(base.data)),3)';
	else
	  % surface
	  baseCoords = (base.coordMap.innerVtcs + corticalDepth * (base.coordMap.outerVtcs-base.coordMap.innerVtcs))';
	end
	% convert to 4xn array
	baseCoords(4,:) = 1;
	% and convert to scan coordinates
	base2scan = viewGet(v,'base2scan',scanNum,params.groupName,baseNum);
	scanCoords = [scanCoords round(base2scan*baseCoords)];
      end
    end
  end
  % check against scandims
  scanDims = viewGet(v,'scanDims',scanNum,params.groupName);
  scanCoords = mrSub2ind(scanDims,scanCoords(1,:),scanCoords(2,:),scanCoords(3,:));
  % remove duplicates and nans
  scanCoords = scanCoords(~isnan(scanCoords));
  scanCoords = unique(scanCoords);
  % convert back to x,y,z coordinates
  [x y z] = ind2sub(scanDims,scanCoords);
elseif strncmp(params.restrict,'ROI: ',5)
  % get the roi name
  roiName = params.restrict(6:end);
  scanCoords = getROICoordinates(v,roiName,scanNum,params.groupName,'straightXform=1');
  if isempty(scanCoords),return,end
  x = scanCoords(1,:);y = scanCoords(2,:);z = scanCoords(3,:);
elseif strncmp(params.restrict,'None',4)
  scanDims = viewGet(v,'scanDims',scanNum,params.groupName);
  [x y z]  = ndgrid(1:scanDims(1),1:scanDims(2),1:scanDims(3));
  x = x(:);y = y(:);z = z(:);
else
  keyboard
end

%check if we have already computed Voxels
if isfield(params,'computedVoxels') && (length(params.computedVoxels)>=scanNum) && ~isempty(params.computedVoxels{scanNum})
  % get scan dims
  scanDims = viewGet(v,'scanDims',scanNum,params.groupName);
  % convert x, y, z to linear coords
  linearCoords = sub2ind(scanDims,x,y,z);
  % get new ones
  newLinearCoords = setdiff(linearCoords,params.computedVoxels{scanNum});
  if length(newLinearCoords) ~= length(linearCoords)
    % show what we are doing
    disp(sprintf('(pRF) Dropping %i voxels that have been already computed',length(linearCoords)-length(newLinearCoords)));
    % convert back to x, y, z
    [x y z] = ind2sub(scanDims,newLinearCoords);
  end
end
%%%%%%%%%%%%%%%%%%%%%%%%
%    checkPRFparams    %
%%%%%%%%%%%%%%%%%%%%%%%%
function params = checkPRFparams(params)


% check the pRFFit params
checkFields = {{'stimImageDiffTolerance',5}...
	       {'recomputeStimImageAndPrefit',0}...
	       {'fitHemodynamic',false}...
	       {'applyFiltering',true}};
for iFit = 1:length(params.fitParams)
  % set defaults
  for iField = 1:length(checkFields)
    if ~isfield(params.fitParams(iFit),checkFields{iField}{1})
      params.fitParams(iFit).(checkFields{iField}{1}) = checkFields{iField}{2};
    end
  end
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%    pRFFitGlobalStimAndPrefit    %
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function [tf cachedVal] = pRFFitGlobalStimAndPrefit(fitParams,groupName,scanNum)

tf = false;cachedVal = [];

% recompute if asked for
if fitParams.recomputeStimImageAndPrefit && (nargout ~=0)
  return
end

global gPRFFitStimAndPrefit;

% make a variable that will be checked for matching
% should contain all fields that could potentially 
% change and force a recompute
fitHash.groupName = groupName;
fitHash.scanNum = scanNum;
fitHash.quickPrefit = fitParams.quickPrefit;
fitHash.xFlipStimulus = fitParams.xFlipStimulus;
fitHash.yFlipStimulus = fitParams.yFlipStimulus;
fitHash.timeShiftStimulus = fitParams.timeShiftStimulus;

% look in cached list 
for iCached = 1:length(gPRFFitStimAndPrefit)
  if isequal(gPRFFitStimAndPrefit(iCached).fitHash,fitHash)
    tf = true;
    break
  end
end

% put in cache, with no output arguments
if nargout == 0
  % keep at most three in cache - so as not to get too big
  iCached = mod(length(gPRFFitStimAndPrefit)+1,3)+1;
  gPRFFitStimAndPrefit(iCached).fitHash = fitHash;
  gPRFFitStimAndPrefit(iCached).val = fitParams;
end

% return value if found
if tf
  cachedVal = gPRFFitStimAndPrefit(iCached).val;
end

%%%%%%%%%%%%%%%%%%%%%%%%%%
%    getModelResidual    %
%%%%%%%%%%%%%%%%%%%%%%%%%%
function r = getModelResidual(params,tSeries,fitParams)

% get model response
global gPRFModels;
[rfModel modelResponse] = feval(gPRFModels(fitParams.modelNum).getModel,params,fitParams);

% normalize response
modelResponse = pRFPreProcess(params,fitParams,modelResponse);

% compute residual or r
if strcmp(fitParams.algorithm,'nelder-mead')
  % calculate correlation of normalized responses
  % Subtract from one since this is a search for minimum
  r = (1-modelResponse * tSeries);
else
  % calculate residual
  residual = tSeries-modelResponse;
end

if fitParams.verbose > 1
  disp(sprintf('r=%f params=[%s]',1-r,mlrnum2str(params)));
end

%%%%%%%%%%%%%%%%%%%%%%%
%    computePrefit    %
%%%%%%%%%%%%%%%%%%%%%%%
function fitParams = computePrefit(fitParams,prefitParams)

% set some variables
fitParams.prefit.n = size(prefitParams,1);
fitParams.prefit.params = prefitParams;

% get number of workers
nProcessors = mlrNumWorkers;

% now start computing prefit
disppercent(-inf,sprintf('(pRFFit) Computing %i prefit model responses using %i processors',fitParams.prefit.n,nProcessors));

% init modelResponse
modelResponse = nan(fitParams.prefit.n,fitParams.concatInfo.runTransition(end,end));

% get hemodynamic parameters
if fitParams.fitHemodynamic
  hemo = pRFGetHemodynamicParams(fitParams);
else
  % not a hemodynamic fit, so hemo parameters get sent to empty
  hemo.initParams = [];
end

% get global that has model function handles
global gPRFModels;
  
% compute all the model response, using parfor loop
parfor i = 1:fitParams.prefit.n
  % get model parameters for this prefit
  params = [fitParams.prefit.params(i,:) hemo.initParams];
  % compute model
  [rfModel modelResponse(i,:)] = feval(gPRFModels(fitParams.modelNum).getModel,params,fitParams);
  % normalize
  modelResponse(i,:) = pRFPreProcess(params,fitParams,modelResponse(i,:));
  % if verbose then print what we are doing
  if fitParams.verbose
    disp(sprintf('(pRFFit) Computing prefit model response %i/%i: [%s]',i,fitParams.prefit.n,mlrnum2str(params)));
  end
end
disppercent(inf);

% keep modelResponses
fitParams.prefit.modelResponse = modelResponse;

