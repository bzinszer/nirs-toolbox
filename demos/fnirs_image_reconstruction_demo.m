%% Image reconstruction demo

% TODO - directory to download the sample data into
root_dir = '/Users/thuppert/Desktop/tmp' ;

% TODO- number of iteractions for ROC curve demo
num_iter = 10;  


% First, lets set up the slab model for generating the forward model and the simulated data
xrange=[-100:5:100];
yrange=[-20:5:50];
zrange=[0:5:20];

[x, y, z] = ndgrid(xrange, yrange, zrange);
n = [x(:) y(:) z(:)];

% elements
e = delaunay(x(:), y(:), z(:));

% faces
f = [e(:, 1:3); e(:,[1 2 4]); e(:, [1 3 4]); e(:, 2:4)];
f = unique(sort(f,2), 'rows');

% This command will create a nirs.core.Mesh data type
mesh = nirs.core.Mesh(n, f, e);

%% Now let's create the probe
noise = nirs.testing.simARNoise();
stim  = nirs.testing.randStimDesign(noise.time, 10, 10, 2);

probe = noise.probe;
% This probe is already [-80 to 80mm, 0 to 25mm, 0] 

% If we add the probe as fiducial markers to the mesh, we can view it
mesh.fiducials=[probe.optodes table(repmat(true,height(probe.optodes),1),'VariableNames',{'Draw'})];
mesh.transparency=.2;  % You can also adjust the transpency of the mesh for drawing
mesh.draw();


%% Simulate some data 
% Let's put a target image in the mesh
targetLoc=[20 0 10; -20 5 10];
extent=[15 15];
Amp=[10 -2; 10 -3];  % Amplitude of the two conditions x HbO2/Hb


mesh.regions=ones(size(mesh.nodes,1),1);
lambda=unique(probe.link.type)';  %List of wavelengths from the probe
prop{1} = nirs.media.tissues.brain(0.7, 50,lambda);

% Now, create the forward model
fwdFEM = nirs.forward.NirfastFEM();
fwdFEM.mesh  = mesh;
fwdFEM.probe = probe;
fwdFEM.prop  = prop;
[J, meas_FEM_baseline] = fwdFEM.jacobian('spectral');


for idx=1:size(targetLoc,1)
    mask(:,idx)=[Amp(idx,1)*(sqrt(sum((mesh.nodes-...
        ones(size(mesh.nodes,1),1)*targetLoc(idx,:)).^2,2))<=extent(idx)); ...
        Amp(idx,2)*(sqrt(sum((mesh.nodes-...
        ones(size(mesh.nodes,1),1)*targetLoc(idx,:)).^2,2))<=extent(idx))];
end

% to draw use:
mesh.draw(mask(1:end/2,1))


% Simulate some data using this defined mask
[data,truth] = nirs.testing.simDataImage(fwdFEM, noise, stim, mask);

% You could also call the simulate image function without the mask.  In
% this case, it will randomly add an image somewhere under the probe
%[data,truth] = nirs.testing.simDataImage(fwdFEM, noise, stim);


%% Now solve the model
j = nirs.modules.TrimBaseline();
j = nirs.modules.OpticalDensity(j);
j = nirs.modules.Resample(j);
j = nirs.modules.AR_IRLS(j);

SubjStats = j.run(data);

% Now, run the image reconstruction job.
j = nirs.modules.ImageReconMFX();
% This job has the following options
%         formula: 'beta ~ cond*group + (1|subject)'   - The mixed effects model to use
%        jacobian: [1x1 Dictionary] - A dictionary to hold the forward model
%     dummyCoding: 'full' - encoding of the mixed effects model
%      centerVars: 0 - center variables in the mixed effects model
%           basis: [1x1 nirs.inverse.basis.identity] - reconstruction basis set
%           prior: [1x1 Dictionary] - priors in the model (default = Min Norm Estimate)
%            mesh: []  - The reconstruction mesh
%           probe: [1x1 Dictionary] - the probe (registered 3D version)
%            name: 'Image Recon w/ Random Effects'
%         prevJob: []




% The jacobian is a dictionary indexed by the subject name (or default)
j.jacobian('default')=J;   % This will assign the same fwd model to all subjects.
% We can also specifiy a different fwd model for each subject 

% The probe Dictionary keys need to match the Jacobian.  But can be default
% (same for all subjects) or specified per subject
j.probe('default')=noise.probe;

% The mesh is needed for drawing purposes (but is not actually used in the
% reconstruction)
j.mesh=mesh;  

% This is the same Wilkinson's notation used in the Mixed Effects and ANOVA
% models.  In this case (since we only have a single subject in this demo),
% let's just use a simple model to make an image per condition
j.formula = 'beta ~ -1 + cond';  % Simple fixed effects model

% This is the basis set used in the image reconstruction.  The options are:
%  nirs.inverse.basis.identity - an identity matrix
%  nirs.inverse.basis.gaussian - a Gaussian smoothing kernel
%  nirs.inverse.basis.freesurfer_wavelet - The spherical wavelet model

j.basis=nirs.inverse.basis.identity(mesh);

%j.basis=nirs.inverse.basis.gaussian(mesh,.1);
% Now create the priors in the model

% This is the Minimum Norm estimate
prior.hbo(:,1)=zeros(size(J.hbo,2),1);
prior.hbr(:,1)=zeros(size(J.hbr,2),1);

% We can also create multiple priors and let the ReML code figure out the
% appropriate weighting
prior2.hbo(:,1)=zeros(size(J.hbo,2),1);
prior2.hbr(:,1)=zeros(size(J.hbr,2),1);

prior2.hbo(:,2)=mask(1:end/2,2);
prior2.hbr(:,2)=mask(end/2+1:end,2);


% The fields and dimensions in in the prior need to match that of the Jacobian
j.prior('A')=prior;
j.prior('B')=prior2;
% Prior is a dictionary and uses the names of the stimulus conditions in the model
% You can also use "default" to use the same prior for all conditions.


ImageStats=j.run(SubjStats);

ImageStats.draw('tstat',[-5 5],'p<0.05');

% For reference, let's show the truth image too.
figure; 
subplot(2,1,1);
mesh.draw(truth(1:end/2,1))
title('Truth- condition A');
subplot(2,1,2);
mesh.draw(truth(1:end/2,2))
title('Truth- condition B');


%% Part 2.  ROC Testing
% We can also run sensitivity-specififty analysis on the image recon model

% Create a ROC object
ROCtest=nirs.testing.ChannelStatsROC;

% Use the simDataImage function to generate some random data
ROCtest.simfunc=@()nirs.testing.simDataImage(fwdFEM, noise, stim);
% We could also give it a mask (as before) to tell the code where to put
% the image (and only the noise would be random), but in this form, the
% code will randomly place the image as well.

% Create a basic processing job 
j = nirs.modules.TrimBaseline();
j = nirs.modules.OpticalDensity(j);
j = nirs.modules.Resample(j);
j = nirs.modules.AR_IRLS(j);       % run the subject level stats
j = nirs.modules.ImageReconMFX(j); % Reconstruct the image

% Set up the reconstruciton job options
j.jacobian('default')=J;
j.probe('default')=noise.probe;
j.mesh=mesh;  
j.formula = 'beta ~ -1 + cond';  % Simple fixed effects model
j.basis=nirs.inverse.basis.identity(mesh);

% Let's use the simple MNE prior this time
prior.hbo(:,1)=zeros(size(J.hbo,2),1);
prior.hbr(:,1)=zeros(size(J.hbr,2),1);
j.prior('default')=prior;


% Assign the job to the ROCtest pipeline
ROCtest.pipeline=j;

% FInally run the ROC for # of iterations
ROCtest=ROCtest.run(num_iter);

% Show the results of the ROC test.
ROCtest.draw;



%% Part 3 Demo of image reconstruction methods using data

if(~exist(root_dir,'dir') || ~exist(fullfile(root_dir,'Image_Recon_Sample'),'dir'))
    mkdir(root_dir);
    disp('downloading sample data from bitbucket.org site');
    %% download the dataset
    urlwrite('https://bitbucket.org/huppertt/nirs-toolbox/downloads/Image_Recon_Sample.zip', ...
        [root_dir filesep 'Image_Recon_Sample.zip']);
    % This command will download the demo_data.zip file from the server.  This
    % step can be skipped if you already downloaded this. This could take a few minutes if your internet conenction is slow
    % The file is about 90Mb in size.
    
    % unzip the data
    unzip([root_dir filesep 'Image_Recon_Sample.zip'],[root_dir filesep]);
    % This will unpack a folder called "data" containing two groups (G1 & G2).
    % A script "simulation.m" is included which was used to generate the data
    % (but is not intended to be run).  The data was simulated from a set of
    % experimental resting state NIRS data with simulated evoked responses
    % added to it to demostrate this analysis pipeline.
    
else
    disp(['Data found in: ' root_dir ': skipping download']);
end

% This data is one of the subject's from:
% Functional near-infrared spectroscopy (fNIRS) of brain function during active balancing using a video game system.
% Karim H1, Schmidt B, Dart D, Beluk N, Huppert T.
% Gait Posture. 2012 Mar;35(3):367-72
% http://www.ncbi.nlm.nih.gov/pubmed/22078300


raw = nirs.io.loadDirectory(fullfile(root_dir,'Image_Recon_Sample'),{});

% Note, the image recon module wants optical density not concentration
j = nirs.modules.TrimBaseline();
j = nirs.modules.OpticalDensity(j);
j = nirs.modules.Resample(j);
j = nirs.modules.AR_IRLS(j);
j.basis('default')=nirs.design.basis.Vestibular;  % Use the custom vestibular basis set

SubjStats = j.run(raw);

% This input function loads an AtlasViewer saved forward model
[Jacobian mesh probe] = nirs.io.loadSensDotMat(fullfile(root_dir,'Image_Recon_Sample','atlasviewer_fwd.mat'));
j = nirs.modules.ImageReconMFX();

% The jacobian is a dictionary indexed by the subject name (or default)
j.jacobian('default')=Jacobian;
j.probe('default')=probe;
j.mesh=mesh;  
j.formula = 'beta ~ -1 + cond';  % Simple fixed effects model

% Let's use the wavelet basis set
j.basis=nirs.inverse.basis.freesurfer_wavelet(5);

%j.basis=nirs.inverse.basis.gaussian(mesh,.01);
% Now create the priors in the model
prior.hbo=zeros(size(Jacobian.hbo,2),1);
prior.hbr=zeros(size(Jacobian.hbr,2),1);
% The fields and dimensions in in the prior need to match that of the Jacobian
j.prior('default')=prior;
% Prior is a dictionary and uses the names of the stimulus conditions in the model

ImageStats=j.run(SubjStats);

h=ImageStats.draw('tstat',[-5 5],'p<0.05');

% Change the view
arrayfun(@(h)view(h,90,0),h);  % Change view to the right
arrayfun(@(h)camroll(h,-90),h); % rotate the image by 90degress
arrayfun(@(h)axis(h,'off'),h); % Turn off the axis



