%% Functional Analysis Scripting Tool - InfraRed (FAST-IR)

% fNIRS analysis script
% Created by Pieter Van den Berghe
% Using Matlab 2023a
% Updated 2024.05.21

% Run using Brain AnalyzIR toolbox Version Version 837 June 12 2020
% Based on the fnirs_analysis_demo scripts from the toolbox. 
% Please do cite the Github repository in case of use

%% 0_locate_toolbox

% Register the location of the toolbox if you are a first-time user

% Locate the Nirs toolbox folder on your drive
toolboxFolder = 'C:\ADJUST-TO-YOUR-DIRECTORY\nirs-toolbox-master';
% Add the folders of the toolbox to the path
addpath(genpath(toolboxFolder));

%% 1_load_data

% Start with a clean slate
clear; clc; close all;

% NOTE REGARDING DATA STRUCTURE:
% This code assumes the following structure for input
% <data folder> / <subject folder> / <subject's .nirs file>
% So, put your data files in the root_dir with subfolders for each subject
% containing the .nirs file

% So the data folder may look like this:
% MyStudy/
%        /Group1/
%               /Subject1/
%                       /2016-03-10_001/<all the shown files above>
%               /Subject2/
%                       /2016-03-11_001
%        /Group2/
%               /Subject3/
%                       /2016-03-10_001
%               /Subject3/
%                       /2016-03-11_001

% Set the location of the dataset on your computer
% dataFolder = 'S:\ge37_kakesten\1-ExperimentfNIRS\12_Data';
dataFolder = 'C:\ADJUST-TO-YOUR-DIRECTORY\Data';
% Set the raw data folder properly
root_dir = uigetdir(dataFolder, 'Select the raw data folder');
% Add the folders of the toolbox to the path
addpath(root_dir);

% Load NIRS and demographic data
raw = nirs.io.loadDirectory(root_dir, {'subject'});
demographics = nirs.createDemographicsTable(raw);

% Show (and check) the short channel labels in the last column
tbl = raw(1).probe.link

%% 2_inspect_channel_quality
% Inspect bad channels with the use of QT-NIRS 
% steps needed for advanced mode (interaction with Brain AnalyzIR)
%   i) Copy the QT.m file to BrainAnalyzIR\+nirs\+modules\ folder
%   ii) Copy the @QTNirs folder to BrainAnalyzIR\+nirs\+core\ folder
% and run 'setpaths'
% QT-NIRS quality assessment
j = nirs.modules.QT();
j.qThreshold = 0.7; % We require at least 80% of good data in every channel
j.sciThreshold = 0.8;
j.pspThreshold = 0.1;
% Data to be considered: "resting" the whole timeseries
j.condMask = 'resting'; 
j.fCut = [0.5 2.0];
j.windowSec = 5; % We will consider 5-sec windows
ScansQuality = j.run(raw);
% ScansQuality.drawGroup('sqmask');
ScansQuality.drawGroup('bar');

%% 3_prepare_stimuli

% Create and run a job to keep the condition(s) of interest
j = nirs.modules.KeepStims();
j.listOfStims = {'stim_channel1','stim_channel2','stim_channel3','stim_channel4','stim_channel5'};
prep = j.run(raw);

% change stimulus durations (to the longest duration of a sentence)
prep = nirs.design.change_stimulus_duration(raw,{'stim_channel1','stim_channel2','stim_channel3','stim_channel4','stim_channel5'}, 12.50012); % pvdb: adjusted from 30 s to the mean duration of the audio clips played in a condition

% Run a job to trim the time-series of the respective condition
j = nirs.modules.TrimBaseline(j);
prep = j.run(prep);

% Check the stimuli timing 
% prep = nirs.viz.StimUtil(prep) % UNCOMMENT TO CHECK

% rename stim marker(s)
j = nirs.modules.RenameStims();
j.listOfChanges = {'stim_channel1', '1_NoNoise'; 'stim_channel2', 'SNR0'; 'stim_channel3', 'SNRplus3'; 'stim_channel4', 'SNRminus3'; 'stim_channel5', 'Control'};
prep = j.run(prep);

% %save the modified stimuli
% save('data_1prepared.mat','raw','prep'); % UNCOMMENT TO SAVE

%% 4_preprocessing 

% Load prepared data
% load('data_1prepared.mat'); % UNCOMMENT TO LOAD

% Create job to do preprocessing: 
j = nirs.modules.OpticalDensity();

% Perform Temporal Derivative Distribution Repair 
j = nirs.modules.TDDR(j); 
j.usePCA = 1; % recommended by the developer of the toolbox T. Huppert (cf. https://youtu.be/fBgbHgFubyI?t=1659)

% Convert to Optical Density
OD = j.run(prep);

% Set the partial pathlength factor to 6 instead of 0.1
% The arugument (made by R Luke and M Yucel) is that "PVC is not well known
% and varies across the head and the task" (see https://github.com/mne-tools/mne-python/pull/9843)
j = nirs.modules.BeerLambertLaw_PPF6(); % PPF is set to 6 instead of the default 5 / 50;
hb = j.run(OD);

% filtering in an attempt to remove slow drifts and components related to heart rate
jobs = nirs.modules.Run_HOMER2(); 
jobs.fcn = 'hmrBandpassFilt'; % indicate the function for applying the bandpass filter
jobs.vars.lpf = 0.4; % define the low-pass cut-off frequency
jobs.vars.hpf = 0.02; % define the high-pass cut-off frequency (0 for no high-pass filter)
hb = jobs.run(hb); % execute third-order Butterworth IIR filter

% Resample the data if the data were sampled at a high sampling frequency. 
% Resampling to 4 Hz will speed up the regressions 
j = nirs.modules.Resample(); 
j.Fs = 4; 
hb = j.run(hb);

% Remove bad channels. Channel pruning based on QTNIRS results
hb_pruned = hb;
for i=1:length(raw)
   hb(i) = hb(i).sorted({'source', 'detector', 'type'});
   idxBadChQT = find(ScansQuality(i).qMats.MeasListAct==0);
   fprintf('Scan:%i #BadChannels:%i\n',i,length(idxBadChQT)/2);
   hb_pruned(i).data(:,idxBadChQT) = nan;
end

% %save the results
%save('data_2preprocessed.mat', "OD", "hb"); % UNCOMMENT TO SAVE

%% 5_analysis_subject

% Load preprocessed data
% load('data_2preprocessed.mat'); % UNCOMMENT TO LOAD

% create activation job to run subject-level statistics
j = nirs.modules.GLM();  
% set verbose function
j.verbose = true; 
% add signal from short channel as a regressor in the model
j.AddShortSepRegressors = true;
% show parameters of GLM
disp(j) 

% Execute the job and store the output to SubjStats variable
tic;
SubjStats = j.run(hb_pruned);
toc

% save_output-subjects
% Visualize and save the figures per condition for each subject
dirFigures = 'C:\ADJUST-TO-YOUR-DIRECTORY\analysis_figures\';
cd(dirFigures)

%
for i = 1 : size(SubjStats,2)
    folder = [dirFigures filesep demographics.subject{i}];
    SubjStats(i).printAll('tstat', [-10 10], 'q < 0.05', folder, 'jpg');
end

% %save the results
%save('data_3activation_subject.mat','SubjStats') % UNCOMMENT TO SAVE

%% 6_analysis_group 

% Load individual activation data
% load('data_3activation_subject.mat'); % UNCOMMENT TO LOAD


% Quality assurance for Subject Level Stats

% generates a table with leverage for subj, condition & channel
groupLeverage = nirs.util.grouplevelleveragestats(SubjStats);

% Remove outlier subjects
j = nirs.modules.RemoveOutlierSubjects();
GoodSubjs = j.run(SubjStats);


% Run a group-level analysis

% This module computes group level statistics using a mixed effects model.
j = nirs.modules.MixedEffects();% run the "fitlme" function which supports 
% a range of models and allows random effects terms to be included.
disp(j) % show default parameters

% Specify the formula for the mixed effects.  
j.formula = 'beta ~ -1 + cond + (1|subject)'; % basic MFX model with 
% conditions as fixed effect and subjects as random effect 

% Let's run robust stats, include diagnostics, and print
% what is happening while the model runs
j.robust = true;
% j.include_diagnostics = true;
j.verbose = true;
% run job and save output to new GroupStats variable
GroupStats = j.run(GoodSubjs);

% Display a table of all stats
disp(GroupStats.table());

% Vizualise the Group Stats for the conditions relative to baseline
% Draw the probe using t-stat & false discovery rate (q value)
figs = GroupStats.draw('tstat', [-4 4], 'q < 0.05');

%% 7_evaluate_conditions
% Contrasts between conditions
% Option to look at what the conditions (regression variables) are:
disp(GroupStats.conditions);

% specify a contrast vector
c = [1 0 -1 0 0]; % contrast the 1st (Control) and 3th (SNR-3) conditions % ADJUST ACCORDING TO YOUR CONDITIONS

% % Calculate stats with the ttest function
ContrastStats = GroupStats.ttest(c);
ContrastStats.draw('tstat',[-4 4],'q<0.05')

%% 8_save_groupOutput
mkdir('figures_group'); % create an empty subfolder for the figures in your folder
figs_folder = [pwd, '\figures_group']; % need to make this folder if it doesn't already exist
GroupStats.printAll('tstat', [-4 4], 'q < 0.05', figs_folder, 'tif')
% ContrastStats.printAll('tstat', [-10 10], 'q < 0.05', figs_folder, 'tif')

% %save the stats tables
mkdir('results');
stats_folder = [pwd, '\results']; % need to make this folder if it doesn't already exist
writetable(GroupStats.table(),[stats_folder filesep 'GroupStats.csv'])
% writetable(ContrastStats.table(),[stats_folder filesep 'ContrastStats.csv'])

% %save the workspace
% save('data_4activation_group.mat','SubjStats','GoodSubjs','GroupStats','figs'); % UNCOMMENT TO SAVE 
close all