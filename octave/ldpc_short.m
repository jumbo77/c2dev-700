% ldpc.m
%
% David Rowe Mar 2017
% Based on Bill Cowley's LDPC simulations
%
% Octave simulation of BPSK with short LDPC codes developed by Bill.  First step
% in use of LDPC codes with FreeDV and Codec 2 700C.
%
% NOTE: You will need to set the CML path in the call to init_cml() below
%       for you CML install.  See lpdc.m for instructions on how to install 
%       CML library

1;
pkg load communications


function init_cml(path_to_cml)
  currentdir = pwd;
  
  if exist(path_to_cml, 'dir') == 7
    cd(path_to_cml)
    CmlStartup      
    cd(currentdir); 
  else
    printf("\n---------------------------------------------------\n");
    printf("Can't start CML in path: %s\n", path_to_cml);
    printf("See CML path instructions at top of this script\n");
    printf("-----------------------------------------------------\n\n");
    assert(0);
  end
end


function sim_out = run_sim(sim_in, HRA, Ntrials)

  genie_Es    = sim_in.genie_Es;
  packet_size = sim_in.packet_size;
  code        = sim_in.code;
  hf_en       = sim_in.hf_en;
  Esvec       = sim_in.Esvec;

  if strcmp(code, 'golay')
    rate = 0.5;
    code_param.data_bits_per_frame = 12;
    framesize = 24;
  end
  if strcmp(code, 'ldpc')
    [Nr Nc] = size(HRA);
    rate = (Nc-Nr)/Nc;
    framesize = Nc;
    modulation = 'BPSK';
    demod_type = 0;
    decoder_type = 0;
    max_iterations = 100;
    [H_rows, H_cols] = Mat2Hrows(HRA);
    code_param.H_rows = H_rows;
    code_param.H_cols = H_cols;
    code_param.P_matrix = [];
    code_param.data_bits_per_frame = length(code_param.H_cols) - length( code_param.P_matrix );
  end
  if strcmp(code, 'diversity')
    rate = 0.5;
    code_param.data_bits_per_frame = 7;
    framesize = 14;
  end

  mod_order = 2;
  bps = code_param.bits_per_symbol = log2(mod_order);

  % init HF model

  if hf_en

    % some typical values

    Rs = 50; dopplerSpreadHz = 1.0; path_delay = 1E-3*Rs;

    nsymb = Ntrials*framesize*bps;
    spread1 = doppler_spread(dopplerSpreadHz, Rs, nsymb);
    spread2 = doppler_spread(dopplerSpreadHz, Rs, nsymb);
    hf_gain = 1.0/sqrt(var(spread1)+var(spread2));
    % printf("nsymb: %d lspread1: %d\n", nsymb, length(spread1));
  end

  % loop around each Esvec point

  for ne = 1:length(Esvec)
    Es = Esvec(ne);
    EsNo = 10^(Es/10);
    EbNodB = Es - 10*log10(code_param.bits_per_symbol * rate);

    Terrs = 0;  Tbits = 0;  Ferrs = 0;
    tx_bits = rx_bits = [];
    hfi = 1;

    for nn = 1: Ntrials
      data = round( rand( 1, code_param.data_bits_per_frame ) );
      tx_bits = [tx_bits data];
      if strcmp(code, 'golay')
        codeword = egolayenc(data);
      end
      if strcmp(code, 'ldpc')
        codeword = LdpcEncode( data, code_param.H_rows, code_param.P_matrix );
      end
      if strcmp(code, 'diversity')
        codeword = [data data];
      end

      code_param.code_bits_per_frame = length( codeword );
      Nsymb = code_param.code_bits_per_frame/bps;

      % modulate

      s = 1 - 2 * codeword;
      code_param.symbols_per_frame = length( s );

      if hf_en

        % simplified rate Rs simulation model that doesn't include
        % ISI, just freq filtering.  We assume perfect phase estimation
        % so it's just amplitude distortion.

        for i=1:length(s)

          % 1.5*Rs carrier spacing, symbols mapped to 14 carriers
          % OK we'd probably use QPSK in practice but meh a few approximations....

          w = 1.5*mod(i,14)*2*pi;
          hf_model(i) = hf_gain*(spread1(hfi) + exp(-j*w*path_delay)*spread2(hfi));
          s(i) *= abs(hf_model(i));
          hfi++;
        end
      end

      variance = 1/(2*EsNo);
      noise = sqrt(variance)* randn(1,code_param.symbols_per_frame);
      r = s + noise;

      Nr = length(r);

      if strcmp(code, 'golay')
        detected_data = egolaydec(r < 0);
        detected_data = detected_data(code_param.data_bits_per_frame+1:framesize);
      end

      if strcmp(code, 'ldpc')

        % in the binary case the LLRs are just a scaled version of the rx samples ...
        % if the EsNo is known -- use the following

        if (genie_Es)
	  input_decoder_c = 4 * EsNo * r;
        else
          r = r / mean(abs(r));       % scale for signal unity signal
	  estvar = var(r-sign(r));
	  estEsN0 = 1/(2* estvar);
	  input_decoder_c = 4 * estEsN0 * r;
        end

        [x_hat, PCcnt] = MpDecode( input_decoder_c, code_param.H_rows, code_param.H_cols, ...
                                   max_iterations, decoder_type, 1, 1);
        Niters = sum(PCcnt!=0);
        detected_data = x_hat(Niters,:);

        if isfield(sim_in, "c_include_file") 

          % optionally dump code and unit test data to a C header file

          code_param.c_include_file = sim_in.c_include_file;
          ldpc_gen_h_file(code_param, max_iterations, decoder_type, input_decoder_c, x_hat, detected_data);
        end

        detected_data = detected_data(1:code_param.data_bits_per_frame);
      end

      if strcmp(code, 'diversity')
        detected_data = (r(1:7) + r(8:14)) < 0;
      end

      rx_bits = [rx_bits detected_data];

      error_positions = xor( detected_data, data );
      Nerrs = sum(error_positions);

      if Nerrs>0,  Ferrs = Ferrs +1;  end
      Terrs = Terrs + Nerrs;
      Tbits = Tbits + code_param.data_bits_per_frame;

    end

    % count packet errors using supplied packet size.  Operating one
    % one big string of bits lets us account for cases were FEC framesize
    % is less than packet size

    error_positions = xor(tx_bits, rx_bits);
    Perrs = 0; Tpackets = 0;
    for i=1:packet_size:length(tx_bits)-packet_size
      Nerrs = sum(error_positions(i:i+packet_size-1));
      if Nerrs>0,  Perrs = Perrs +1;  end
      Tpackets++;
    end

    printf("EbNo: %3.1f dB BER: %5.4f PER: %5.4f Nbits: %4d Nerrs: %4d Tpackets: %4d Perr: %4d\n", EbNodB, Terrs/Tbits, Perrs/ Tpackets, Tbits, Terrs, Tpackets, Perrs);

    TERvec(ne) = Terrs;
    FERvec(ne) = Ferrs;
    BERvec(ne) = Terrs/ Tbits;
    PERvec(ne) = Perrs/ Tpackets;
    Ebvec = Esvec - 10*log10(code_param.bits_per_symbol * rate);

    sim_out.BERvec = BERvec;
    sim_out.PERvec = PERvec;
    sim_out.Ebvec = Ebvec;
    sim_out.FERvec = FERvec;
    sim_out.TERvec  = TERvec;
    sim_out.framesize = framesize;
    sim_out.error_positions = error_positions;
  end
endfunction


function plot_curves(hf_en)

  if hf_en
    epslabel = 'hf';
  else
    epslabel = 'awgn';
  end

  Ntrials = 500;

  sim_in.genie_Es    = 1;
  sim_in.packet_size = 28;
  sim_in.code        = 'ldpc';
  sim_in.hf_en       = hf_en;

  if hf_en
    Esvec = 0:0.5:9;
  else
    Esvec = -3:0.5:3;
  end
  sim_in.Esvec = Esvec;

  load HRA_112_112.txt
  load HRA_112_56.txt
  load HRA_56_56.txt
  load HRA_56_28.txt

  sim_out1 = run_sim(sim_in, HRA_112_112, Ntrials);
  sim_out2 = run_sim(sim_in, HRA_112_56 , Ntrials);
  sim_out3 = run_sim(sim_in, HRA_56_56  , Ntrials*2);
  sim_out4 = run_sim(sim_in, HRA_56_28  , Ntrials*2);
  sim_in.code = 'golay';
  sim_out5 = run_sim(sim_in, [], Ntrials*10);
  sim_in.code = 'diversity';
  sim_out6 = run_sim(sim_in, [], Ntrials*10);

  if hf_en
    Ebvec_theory = 2:0.5:12;
    EbNoLin = 10.^(Ebvec_theory/10);
    uncoded_BER_theory = 0.5.*(1-sqrt(EbNoLin./(EbNoLin+1)));
  else
    Ebvec_theory = 0:0.5:8;
    uncoded_BER_theory = 0.5*erfc(sqrt(10.^(Ebvec_theory/10)));
  end

  % need standard packet size to compare
  % packet error if bit 0, or bit 1, or bit 2 .....
  %              or bit 0 and bit 1
  % no packet error if all bits ok (1-p(0))*(1-p(1))
  % P(packet error) = p(0)+p(1)+....

  uncoded_PER_theory = 1 - (1-uncoded_BER_theory).^sim_in.packet_size;

  figure(1); clf;
  semilogy(Ebvec_theory,  uncoded_BER_theory, 'b+-;BPSK theory;','markersize', 10, 'linewidth', 2)
  hold on;
  semilogy(sim_out1.Ebvec, sim_out1.BERvec, 'g+-;rate 1/2 HRA 112 112;','markersize', 10, 'linewidth', 2)
  semilogy(sim_out2.Ebvec, sim_out2.BERvec, 'r+-;rate 2/3 HRA 112 56;','markersize', 10, 'linewidth', 2)
  semilogy(sim_out3.Ebvec, sim_out3.BERvec, 'c+-;rate 1/2 HRA 56 56;','markersize', 10, 'linewidth', 2)
  semilogy(sim_out4.Ebvec, sim_out4.BERvec, 'k+-;rate 2/3 HRA 56 28;','markersize', 10, 'linewidth', 2)
  semilogy(sim_out5.Ebvec, sim_out5.BERvec, 'm+-;rate 1/2 Golay (24,12);','markersize', 10, 'linewidth', 2)
  semilogy(sim_out6.Ebvec, sim_out6.BERvec, 'go-;rate 1/2 Diversity;','markersize', 10, 'linewidth', 2)
  hold off;
  xlabel('Eb/No')
  ylabel('BER')
  grid
  legend("boxoff");
  axis([min(Ebvec_theory) max(Ebvec_theory) 1E-3 2E-1]);
  epsname = sprintf("ldpc_short_%s_ber.eps", epslabel);
  print('-deps', '-color', epsname)

  figure(2); clf;
  semilogy(Ebvec_theory,  uncoded_PER_theory, 'b+-;BPSK theory;','markersize', 10, 'linewidth', 2)
  hold on;
  semilogy(sim_out1.Ebvec, sim_out1.PERvec, 'g+-;rate 1/2 HRA 112 112;','markersize', 10, 'linewidth', 2)
  semilogy(sim_out2.Ebvec, sim_out2.PERvec, 'r+-;rate 2/3 HRA 112 56;','markersize', 10, 'linewidth', 2)
  semilogy(sim_out3.Ebvec, sim_out3.PERvec, 'c+-;rate 1/2 HRA 56 56;','markersize', 10, 'linewidth', 2)
  semilogy(sim_out4.Ebvec, sim_out4.PERvec, 'k+-;rate 2/3 HRA 56 28;','markersize', 10, 'linewidth', 2)
  semilogy(sim_out5.Ebvec, sim_out5.PERvec, 'm+-;rate 1/2 Golay (24,12);','markersize', 10, 'linewidth', 2)
  semilogy(sim_out6.Ebvec, sim_out6.PERvec, 'go-;rate 1/2 Diversity;','markersize', 10, 'linewidth', 2)
  hold off;
  xlabel('Eb/No')
  ylabel('PER')
  grid
  legend("boxoff");
  if hf_en
    legend("location", "southwest");
  end
  axis([min(Ebvec_theory) max(Ebvec_theory) 1E-2 1]);
  epsname = sprintf("ldpc_short_%s_per.eps", epslabel);
  print('-deps', '-color', epsname)
endfunction


function run_single(bits, code = 'ldpc', channel = 'awgn', EbNodB, error_pattern_filename)

  sim_in.code = code;
  load HRA_112_112.txt

  if strcmp(code, 'ldpc')
    data_bits_per_frame = 112;
    rate = 0.5;
  end

  if strcmp(code, 'diversity')
    data_bits_per_frame = 7;
    rate = 0.5;
  end

  Ntrials = bits/data_bits_per_frame;
  sim_in.genie_Es    = 1;
  sim_in.packet_size = 28;

  if strcmp(channel, 'awgn')
    sim_in.hf_en = 0;
    sim_in.Esvec = EbNodB + 10*log10(rate);
  else
    sim_in.hf_en = 1;
    sim_in.Esvec = EbNodB + 10*log10(rate);
  end

  sim_out = run_sim(sim_in, HRA_112_112, Ntrials);

  if nargin == 5
    fep = fopen(error_pattern_filename, "wb");
    fwrite(fep, sim_out.error_positions, "short");
    fclose(fep);
  end

  figure
  plot(sim_out.error_positions);
  axis([1 length(sim_out.error_positions) -0.2 1.2])
endfunction


% Used to generate C header file for C port

function run_c_header

  sim_in.code = 'ldpc';
  load HRA_112_112.txt
  data_bits_per_frame = 112;
  rate = 0.5;
  bits = data_bits_per_frame;
  Ntrials = bits/data_bits_per_frame;
  sim_in.genie_Es    = 1;
  sim_in.packet_size = 28;
  EbNodB = 2;
  sim_in.hf_en = 0;
  sim_in.Esvec = EbNodB + 10*log10(rate);
  sim_in.c_include_file = "../src/HRA_112_112.h";

  sim_out = run_sim(sim_in, HRA_112_112, Ntrials);
endfunction


% Start simulation here ----------------------------------------------

% change this path for your CML installation

init_cml('/home/david/Desktop/cml');

rand('seed',1);
randn('seed',1);
more off;
format;
close all;

% plotting curves (may take a while)

%plot_curves(0);
%plot_curves(1);

% generating error files 

run_single(700*10, 'ldpc', 'awgn', 2, 'awgn_2dB_ldpc.err')
run_single(700*10, 'diversity', 'awgn', 2, 'awgn_2dB_diversity.err')
run_single(700*10, 'ldpc', 'hf', 6, 'hf_6dB_ldpc.err')
run_single(700*10, 'diversity', 'hf', 6, 'hf_6dB_diversity.err')

% generate C header for C port of code

%run_c_header
